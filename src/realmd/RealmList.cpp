/*
 * Copyright (C) 2005-2011 MaNGOS <http://getmangos.com/>
 * Copyright (C) 2009-2011 MaNGOSZero <https://github.com/mangos/zero>
 * Copyright (C) 2011-2016 Nostalrius <https://nostalrius.org>
 * Copyright (C) 2016-2017 Elysium Project <https://github.com/elysium-project>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

/** \file
    \ingroup realmd
*/

#include "Common.h"
#include "RealmList.h"
#include "AuthCodes.h"
#include "Util.h"
#include "Policies/SingletonImp.h"
#include "Database/DatabaseEnv.h"
#include "Config/Config.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <vector>

RealmList sRealmList;

namespace
{
    struct AllowedClientVariant
    {
        RealmBuildInfo info;
        std::string platform;
        std::string os;
    };

    typedef std::map<uint16, std::vector<AllowedClientVariant>> AllowedClientBuildMap;

    AllowedClientBuildMap sAllowedClientBuilds;

    std::string NormalizeClientToken(std::string token)
    {
        std::string out;
        out.reserve(token.size());

        for (char ch : token)
        {
            if (!std::isspace(static_cast<unsigned char>(ch)))
                out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
        }

        return out;
    }

    std::string ClientTokenFromValue(uint32 value)
    {
        char token[5] = {};
        memcpy(token, &value, sizeof(value));
        token[4] = '\0';
        return NormalizeClientToken(token);
    }

    bool LoadHashFromField(Field const& field, std::array<uint8, 20>& outHash)
    {
        if (field.IsNULL())
            return true;

        std::string hash = field.GetCppString();
        if (hash.empty())
            return true;

        if (hash.size() != 40)
            return false;

        HexStrToByteArray(hash, outHash.data());
        return true;
    }

    RealmBuilds ParseRealmBuilds(std::string const& realmbuilds)
    {
        RealmBuilds builds;
        Tokens tokens = StrSplit(realmbuilds, " ,");

        for (std::string const& token : tokens)
        {
            uint32 build = static_cast<uint32>(atoi(token.c_str()));
            if (build)
                builds.insert(build);
        }

        return builds;
    }

    RealmBuildInfo MakeRealmBuildInfoForRealm(RealmBuilds const& builds)
    {
        RealmBuildInfo buildInfo;

        // Older realm-list paths still expect one representative version label,
        // so prefer the highest known concrete build when a realm supports several.
        for (auto itr = builds.rbegin(); itr != builds.rend(); ++itr)
        {
            if (RealmBuildInfo const* supportedBuild = FindBuildInfo(static_cast<uint16>(*itr)))
                return *supportedBuild;
        }

        return buildInfo;
    }

    RealmBuildInfo const* SelectBuildInfoVariant(uint16 build, std::string const& os, std::string const& platform)
    {
        auto const itr = sAllowedClientBuilds.find(build);
        if (itr == sAllowedClientBuilds.end() || itr->second.empty())
            return nullptr;

        AllowedClientVariant const* fallback = nullptr;
        AllowedClientVariant const* platformMatch = nullptr;

        for (AllowedClientVariant const& variant : itr->second)
        {
            if (!fallback)
                fallback = &variant;

            bool const osMatches = variant.os.empty() || variant.os == os;
            bool const platformMatches = variant.platform.empty() || variant.platform == platform;

            if (osMatches && platformMatches)
            {
                if (variant.os == os && variant.platform == platform)
                    return &variant.info;

                if (!platformMatch && variant.platform == platform)
                    platformMatch = &variant;
            }
        }

        if (platformMatch)
            return &platformMatch->info;

        return fallback ? &fallback->info : nullptr;
    }
}

RealmBuildInfo const* FindBuildInfo(uint16 _build)
{
    return SelectBuildInfoVariant(_build, "", "");
}

RealmBuildInfo const* FindBuildInfo(uint16 _build, uint32 os, uint32 platform)
{
    return SelectBuildInfoVariant(_build, ClientTokenFromValue(os), ClientTokenFromValue(platform));
}

std::string GetBuildVersionString(RealmBuildInfo const& buildInfo)
{
    std::ostringstream version;
    version << uint32(buildInfo.major_version) << '.'
            << uint32(buildInfo.minor_version) << '.'
            << uint32(buildInfo.bugfix_version);

    if (buildInfo.hotfix_version)
        version << '.' << uint32(buildInfo.hotfix_version);

    return version.str();
}

RealmList::RealmList() : m_UpdateInterval(0), m_NextUpdateTime(time(nullptr))
{
}

void RealmList::Initialize(uint32 updateInterval)
{
    m_UpdateInterval = updateInterval;

    LoadAllowedClients();
    UpdateRealms(true);
}

void RealmList::LoadAllowedClients()
{
    sAllowedClientBuilds.clear();

    // realmd owns login/build-display truth. Each enabled row represents one
    // concrete client build variant and carries the hashes used by strict proof
    // checks when we turn exact version enforcement back on.
    std::unique_ptr<QueryResult> result(LoginDatabase.Query(
        "SELECT build, major_version, minor_version, bugfix_version, hotfix_version, platform, os, windows_hash, mac_hash "
        "FROM allowed_clients WHERE enabled = 1 ORDER BY build, platform, os"));

    if (!result)
    {
        sLog.outError("No enabled rows found in `allowed_clients`; realmd will reject all client builds.");
        return;
    }

    do
    {
        Field* fields = result->Fetch();

        AllowedClientVariant variant;
        variant.info.build = fields[0].GetUInt16();
        variant.info.major_version = fields[1].GetUInt8();
        variant.info.minor_version = fields[2].GetUInt8();
        variant.info.bugfix_version = fields[3].GetUInt8();
        variant.info.hotfix_version = fields[4].GetUInt8();
        variant.platform = NormalizeClientToken(fields[5].GetCppString());
        variant.os = NormalizeClientToken(fields[6].GetCppString());

        if (!LoadHashFromField(fields[7], variant.info.WindowsHash))
            sLog.outError("Invalid windows_hash for build %u (%s/%s); leaving zero hash.", variant.info.build, variant.platform.c_str(), variant.os.c_str());

        if (!LoadHashFromField(fields[8], variant.info.MacHash))
            sLog.outError("Invalid mac_hash for build %u (%s/%s); leaving zero hash.", variant.info.build, variant.platform.c_str(), variant.os.c_str());

        sAllowedClientBuilds[variant.info.build].push_back(variant);
    } while (result->NextRow());

    sLog.outString("Loaded %u allowed client build entries.", static_cast<uint32>(sAllowedClientBuilds.size()));
}

void RealmList::UpdateRealm(uint32 ID, const std::string& name, const std::string& address, uint32 port, uint8 icon, RealmFlags realmflags, uint8 timezone, AccountTypes allowedSecurityLevel, float popu, const std::string& realmbuilds)
{
    Realm& realm = m_realms[name];

    realm.m_ID = ID;
    realm.icon = icon;
    realm.realmflags = realmflags;
    realm.timezone = timezone;
    realm.allowedSecurityLevel = allowedSecurityLevel;
    realm.populationLevel = popu;
    realm.realmbuilds = realmbuilds;
    // Realm membership in realmd is driven by the login-side build numbers from
    // realmlist.realmbuilds. Turtle's world handshake may still need a separate
    // compatibility list on mangosd, so keep that concern out of this registry.
    realm.allowedBuilds = ParseRealmBuilds(realmbuilds);
    realm.realmBuildInfo = MakeRealmBuildInfoForRealm(realm.allowedBuilds);

    std::ostringstream ss;
    ss << address << ":" << port;
    realm.address = ss.str();
}

void RealmList::UpdateIfNeed()
{
    if (!m_UpdateInterval || m_NextUpdateTime > time(nullptr))
        return;

    m_NextUpdateTime = time(nullptr) + m_UpdateInterval;

    m_realms.clear();
    UpdateRealms(false);
}

void RealmList::UpdateRealms(bool init)
{
    DETAIL_LOG("Updating Realm List...");

    QueryResult* result = LoginDatabase.Query(
        "SELECT id, name, address, port, icon, realmflags, timezone, "
        "allowedSecurityLevel, population, realmbuilds FROM realmlist "
        "WHERE (realmflags & 1) = 0 ORDER BY name");

    static const std::string overrideAddrStr = sConfig.GetStringDefault("HostAddressOverride", "0.0.0.0");
    static bool overrideAddr = (overrideAddrStr.compare("0.0.0.0") != 0);

    if (result)
    {
        do
        {
            Field* fields = result->Fetch();
            uint8 allowedSecurityLevel = fields[7].GetUInt8();
            uint8 realmflags = fields[5].GetUInt8();
            std::string realmAddress = overrideAddr ? overrideAddrStr : fields[2].GetCppString();

            if (realmflags & ~(REALM_FLAG_OFFLINE | REALM_FLAG_NEW_PLAYERS | REALM_FLAG_RECOMMENDED | REALM_FLAG_SPECIFYBUILD))
            {
                sLog.outError("Realm allowed have only OFFLINE Mask 0x2), or NEWPLAYERS (mask 0x20), or RECOMENDED (mask 0x40), or SPECIFICBUILD (mask 0x04) flags in DB");
                realmflags &= (REALM_FLAG_OFFLINE | REALM_FLAG_NEW_PLAYERS | REALM_FLAG_RECOMMENDED | REALM_FLAG_SPECIFYBUILD);
            }

            UpdateRealm(
                fields[0].GetUInt32(), fields[1].GetCppString(), realmAddress, fields[3].GetUInt32(),
                fields[4].GetUInt8(), RealmFlags(realmflags), fields[6].GetUInt8(),
                (allowedSecurityLevel <= SEC_SIGMACHAD ? AccountTypes(allowedSecurityLevel) : SEC_SIGMACHAD),
                fields[8].GetFloat(), fields[9].GetCppString());

            if (init)
                sLog.outString("Welcome to Turtle WoW!");
            sLog.outString("Login server is up and running.");
        } while (result->NextRow());
        delete result;
    }
}
