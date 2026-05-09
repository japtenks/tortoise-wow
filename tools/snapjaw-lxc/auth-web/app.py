#!/usr/bin/env python3
import hashlib
import os
import re
import secrets
import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterable

import pymysql
from flask import Flask, abort, flash, g, redirect, render_template_string, request, session, url_for


app = Flask(__name__)
APP_SECRET = os.environ.get("AUTH_WEB_SECRET", "").strip()
if not APP_SECRET:
    raise RuntimeError("AUTH_WEB_SECRET must be set")
app.secret_key = APP_SECRET
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
)

DB_HOST = os.environ.get("AUTH_WEB_DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("AUTH_WEB_DB_PORT", "3306"))
DB_USER = os.environ.get("AUTH_WEB_DB_USER", "torta")
DB_PASSWORD = os.environ.get("AUTH_WEB_DB_PASSWORD", "torta")
LOGIN_DB = os.environ.get("AUTH_WEB_LOGIN_DB", "snapjawrealmd")
CHARACTER_DBS = [
    db.strip()
    for db in os.environ.get("AUTH_WEB_CHARACTER_DBS", "stablecharacters,ptrcharacters").split(",")
    if db.strip()
]
WEB_PORT = int(os.environ.get("AUTH_WEB_PORT", "8080"))
MONEY_BOOST_COPPER = int(os.environ.get("AUTH_WEB_MONEY_BOOST_COPPER", "10000000"))
LEVEL_BOOST = int(os.environ.get("AUTH_WEB_LEVEL_BOOST", "60"))
LOGIN_THROTTLE_WINDOW_SECONDS = int(os.environ.get("AUTH_WEB_LOGIN_THROTTLE_WINDOW_SECONDS", "300"))
LOGIN_THROTTLE_MAX_ATTEMPTS = int(os.environ.get("AUTH_WEB_LOGIN_THROTTLE_MAX_ATTEMPTS", "5"))
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_]{3,16}$")
BOOTSTRAP_ADMIN_KEY = os.environ.get("AUTH_WEB_BOOTSTRAP_ADMIN_KEY", "").strip()
PENDING_COMMAND_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,15}$")
DB_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
FAILED_LOGIN_ATTEMPTS: dict[str, list[float]] = {}
T1_TRINKET_ITEMS = [13965, 18820]
CLASS_T1_ITEMS = {
    1: [16861, 16862, 16863, 16864, 16865, 16866, 16867, 16868],
    2: [16853, 16854, 16855, 16856, 16857, 16858, 16859, 16860],
    3: [16845, 16846, 16847, 16848, 16849, 16850, 16851, 16852],
    4: [16820, 16821, 16822, 16823, 16824, 16825, 16826, 16827],
    5: [16811, 16812, 16813, 16814, 16815, 16816, 16817, 16819],
    7: [16837, 16838, 16839, 16840, 16841, 16842, 16843, 16844],
    8: [16795, 16796, 16797, 16798, 16799, 16800, 16801, 16802],
    9: [16803, 16804, 16805, 16806, 16807, 16808, 16809, 16810],
    11: [16828, 16829, 16830, 16831, 16833, 16834, 16835, 16836],
}
CLASS_LABELS = {
    1: "Warrior",
    2: "Paladin",
    3: "Hunter",
    4: "Rogue",
    5: "Priest",
    7: "Shaman",
    8: "Mage",
    9: "Warlock",
    11: "Druid",
}
CLASS_MASKS = {class_id: 1 << (class_id - 1) for class_id in CLASS_LABELS}
BACKPACK_CONTAINER_SLOT = 255
BAG_SLOT_ITEM = 3762
BAG_EQUIP_SLOTS = [19, 20, 21, 22]
REPLACEABLE_ROOT_SLOTS = list(range(0, 23))
LOADOUT_ITEM_CAPS = {
    10: 18,
    20: 28,
    30: 40,
    40: 52,
    50: 66,
    60: 76,
}
TIER_FILLER_CAPS = {
    "tier1": 66,
    "tier2": 76,
    "tier25": 88,
    "tier3": 92,
}
ARMOR_SUBCLASS_BY_CLASS = {
    1: 4,
    2: 4,
    3: 3,
    4: 2,
    5: 1,
    7: 3,
    8: 1,
    9: 1,
    11: 2,
}
TIER_TOKEN_BY_CLASS = {
    1: {"tier1": "Might", "tier2": "Wrath", "tier25": "Conqueror", "tier3": "Dreadnaught"},
    2: {"tier1": "Lawbringer", "tier2": "Judgment", "tier25": "Avenger", "tier3": "Redemption"},
    3: {"tier1": "Giantstalker", "tier2": "Dragonstalker", "tier25": "Striker", "tier3": "Cryptstalker"},
    4: {"tier1": "Nightslayer", "tier2": "Bloodfang", "tier25": "Deathdealer", "tier3": "Bonescythe"},
    5: {"tier1": "Prophecy", "tier2": "Transcendence", "tier25": "Oracle", "tier3": "Faith"},
    7: {"tier1": "Earthfury", "tier2": "Ten Storms", "tier25": "Stormcaller", "tier3": "Earthshatter"},
    8: {"tier1": "Arcanist", "tier2": "Netherwind", "tier25": "Enigma", "tier3": "Frostfire"},
    9: {"tier1": "Felheart", "tier2": "Nemesis", "tier25": "Doomcaller", "tier3": "Plagueheart"},
    11: {"tier1": "Cenarion", "tier2": "Stormrage", "tier25": "Genesis", "tier3": "Dreamwalker"},
}
LOADOUT_OPTIONS = [
    ("level10", "Level 10 test kit"),
    ("level20", "Level 20 test kit"),
    ("level30", "Level 30 test kit"),
    ("level40", "Level 40 test kit"),
    ("level50", "Level 50 test kit"),
    ("tier1", "Level 60 Tier 1 set"),
    ("tier2", "Level 60 Tier 2 set"),
    ("tier25", "Level 60 Tier 2.5 set"),
    ("tier3", "Level 60 Tier 3 set (highest raid tier)"),
]
ARMOR_SLOT_CONFIGS = [
    {"slot": 0, "inventory_types": (1,), "label": "head"},
    {"slot": 1, "inventory_types": (2,), "label": "neck"},
    {"slot": 2, "inventory_types": (3,), "label": "shoulders"},
    {"slot": 4, "inventory_types": (5, 20), "label": "chest"},
    {"slot": 5, "inventory_types": (6,), "label": "waist"},
    {"slot": 6, "inventory_types": (7,), "label": "legs"},
    {"slot": 7, "inventory_types": (8,), "label": "feet"},
    {"slot": 8, "inventory_types": (9,), "label": "wrists"},
    {"slot": 9, "inventory_types": (10,), "label": "hands"},
    {"slot": 10, "inventory_types": (11,), "label": "ring"},
    {"slot": 11, "inventory_types": (11,), "label": "ring"},
    {"slot": 12, "inventory_types": (12,), "label": "trinket"},
    {"slot": 13, "inventory_types": (12,), "label": "trinket"},
    {"slot": 14, "inventory_types": (16,), "label": "cloak"},
]
WEAPON_SLOT_PLANS = {
    1: [{"slot": 15, "inventory_types": (17,), "subclasses": (1, 5, 6, 8)}],
    2: [{"slot": 15, "inventory_types": (17,), "subclasses": (1, 5, 6, 8)}],
    3: [
        {"slot": 15, "inventory_types": (17,), "subclasses": (1, 6, 8, 10)},
        {"slot": 17, "inventory_types": (15, 26), "subclasses": (2, 3, 18)},
    ],
    4: [
        {"slot": 15, "inventory_types": (13, 21, 22), "subclasses": (0, 4, 7, 13, 15)},
        {"slot": 16, "inventory_types": (13, 22), "subclasses": (0, 4, 7, 13, 15)},
    ],
    5: [{"slot": 15, "inventory_types": (17,), "subclasses": (10,)}],
    7: [{"slot": 15, "inventory_types": (17,), "subclasses": (1, 5, 10)}],
    8: [{"slot": 15, "inventory_types": (17,), "subclasses": (10,)}],
    9: [{"slot": 15, "inventory_types": (17,), "subclasses": (10,)}],
    11: [{"slot": 15, "inventory_types": (17,), "subclasses": (5, 10)}],
}


LAYOUT = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ title }}</title>
  <style>
    :root {
      --bg: #0f1720;
      --panel: #172330;
      --panel-2: #203041;
      --line: #2e435a;
      --text: #e8f0f6;
      --muted: #9fb2c3;
      --accent: #79d2a6;
      --danger: #ff8a8a;
      --warn: #ffd27a;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", Tahoma, sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top left, #21405b 0%, transparent 32%),
        radial-gradient(circle at bottom right, #2f5537 0%, transparent 28%),
        var(--bg);
    }
    a { color: var(--accent); text-decoration: none; }
    .shell {
      max-width: 1080px;
      margin: 0 auto;
      padding: 24px 16px 40px;
    }
    .topbar, .card {
      background: rgba(23, 35, 48, 0.92);
      border: 1px solid var(--line);
      border-radius: 16px;
      box-shadow: 0 20px 40px rgba(0,0,0,0.25);
    }
    .topbar {
      padding: 16px 18px;
      margin-bottom: 18px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .brand { font-weight: 700; letter-spacing: 0.03em; }
    .muted { color: var(--muted); }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 16px;
    }
    .card { padding: 18px; }
    h1, h2, h3 { margin: 0 0 12px; }
    p { line-height: 1.45; }
    label {
      display: block;
      margin: 10px 0 6px;
      font-size: 0.95rem;
      color: var(--muted);
    }
    input, select, button {
      width: 100%;
      border-radius: 10px;
      border: 1px solid var(--line);
      background: var(--panel-2);
      color: var(--text);
      padding: 10px 12px;
      font: inherit;
    }
    button {
      cursor: pointer;
      background: linear-gradient(180deg, #7bc9a2, #4aa277);
      border: none;
      color: #0b1a12;
      font-weight: 700;
    }
    button.secondary {
      background: #31465e;
      color: var(--text);
      border: 1px solid var(--line);
    }
    button.warn {
      background: linear-gradient(180deg, #ffd88f, #e3ad4f);
      color: #241707;
    }
    .actions {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin-top: 14px;
    }
    .actions > * {
      flex: 1 1 160px;
    }
    .flash {
      padding: 12px 14px;
      border-radius: 12px;
      margin-bottom: 12px;
      border: 1px solid var(--line);
      background: rgba(32, 48, 65, 0.92);
    }
    .flash.error { border-color: #6d3434; color: #ffd3d3; }
    .flash.success { border-color: #34624f; color: #d2ffe8; }
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 8px;
      font-size: 0.95rem;
    }
    th, td {
      padding: 10px 8px;
      border-bottom: 1px solid var(--line);
      text-align: left;
      vertical-align: top;
    }
    .inline-form {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
    }
    .inline-form input {
      width: auto;
      min-width: 110px;
      flex: 1 1 110px;
    }
    .inline-form button {
      width: auto;
      min-width: 120px;
    }
    .pill {
      display: inline-block;
      padding: 3px 8px;
      border-radius: 999px;
      background: #2a3e52;
      color: var(--muted);
      font-size: 0.85rem;
    }
    @media (max-width: 700px) {
      .inline-form { flex-direction: column; align-items: stretch; }
      .inline-form button, .inline-form input { width: 100%; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="topbar">
      <div>
        <div class="brand">SnapJaw Auth Portal</div>
        <div class="muted">Registration and light admin for the shared auth server</div>
      </div>
      <div class="muted">
        {% if current_user %}
          Signed in as <strong>{{ current_user["username"] }}</strong>
          {% if current_user["is_web_admin"] %}<span class="pill">admin</span>{% endif %}
          · <a href="{{ url_for('logout') }}">Logout</a>
        {% else %}
          <a href="{{ url_for('login') }}">Login</a>
          · <a href="{{ url_for('register') }}">Register</a>
        {% endif %}
      </div>
    </div>
    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        {% for category, message in messages %}
          <div class="flash {{ category }}">{{ message }}</div>
        {% endfor %}
      {% endif %}
    {% endwith %}
    {{ body|safe }}
  </div>
</body>
</html>
"""


REGISTER_BODY = """
<div class="grid">
  <section class="card">
    <h1>Create Account</h1>
    <p class="muted">Accounts use the same normalized username and password hashing as the core. Portal admin bootstrap requires a separate setup key when no admin exists yet.</p>
    <form method="post">
      <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
      <label>Username</label>
      <input name="username" maxlength="16" required>
      <label>Password</label>
      <input name="password" type="password" maxlength="16" required>
      <label>Email (optional)</label>
      <input name="email" type="email">
      {% if bootstrap_required %}
        <label>Bootstrap admin key</label>
        <input name="bootstrap_admin_key" type="password">
      {% endif %}
      <div class="actions">
        <button type="submit">Create account</button>
      </div>
    </form>
  </section>
  <section class="card">
    <h2>What this page does</h2>
    <p>It creates auth accounts in <code>{{ login_db }}</code>, initializes shop coin rows, and keeps the same <code>SHA1(USERNAME:PASSWORD)</code> hash format the server uses.</p>
    <p class="muted">Current limits: 3-16 characters, letters/numbers/underscore only. Portal admin is separate from in-game GM rank.</p>
  </section>
</div>
"""


LOGIN_BODY = """
<div class="grid">
  <section class="card">
    <h1>Login</h1>
    <form method="post">
      <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
      <label>Username</label>
      <input name="username" maxlength="16" required>
      <label>Password</label>
      <input name="password" type="password" maxlength="16" required>
      <div class="actions">
        <button type="submit">Sign in</button>
      </div>
    </form>
  </section>
  <section class="card">
    <h2>Admin access</h2>
    <p class="muted">Only accounts marked as portal admins can use the admin tools. Normal accounts can still log in here to confirm credentials work.</p>
  </section>
</div>
"""


HOME_BODY = """
<div class="grid">
  <section class="card">
    <h1>Welcome</h1>
    <p>Use this page to register a game account or sign in to the admin tools.</p>
    <div class="actions">
      {% if current_user %}
        {% if current_user["is_web_admin"] %}
          <a href="{{ url_for('admin') }}"><button>Open admin</button></a>
        {% endif %}
      {% else %}
        <a href="{{ url_for('register') }}"><button>Create account</button></a>
        <a href="{{ url_for('login') }}"><button class="secondary">Login</button></a>
      {% endif %}
    </div>
  </section>
  <section class="card">
    <h2>Current v1 scope</h2>
    <p class="muted">Registration, shop coin adjustments, offline character test tweaks, offline loadout presets, and a queued Tier 1 mail preset for quick GM-side checks.</p>
  </section>
</div>
"""


ADMIN_BODY = """
<div class="grid">
  <section class="card">
    <h1>Admin</h1>
    <p class="muted">Browse accounts, reset passwords, remove empty accounts, or apply offline test tweaks to characters.</p>
    <form method="get">
      <label>Account lookup</label>
      <input name="q" value="{{ query or '' }}" placeholder="username">
      <div class="actions">
        <button type="submit">Search</button>
      </div>
    </form>
  </section>
  <section class="card">
    <h2>Safe defaults</h2>
    <p class="muted">Character actions only run for offline characters. The preset boost sets level {{ level_boost }} and money to {{ money_boost_display }} if lower. Loadout presets replace equipped gear plus the four bag slots, but leave money unchanged.</p>
  </section>
</div>

<section class="card" style="margin-top: 16px;">
  <h2>Accounts</h2>
  <p class="muted">Showing {% if query %}accounts matching "{{ query }}"{% else %}the most recent accounts{% endif %}. Password reset uses the same server hash format. Hard delete is limited to offline accounts with no characters.</p>
  {% if accounts %}
    <table>
      <thead>
        <tr>
          <th>Username</th>
          <th>ID</th>
          <th>Email</th>
          <th>Coins</th>
          <th>Chars</th>
          <th>Status</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody>
        {% for listed in accounts %}
          <tr>
            <td><a href="{{ url_for('admin', q=listed['username']) }}">{{ listed["username"] }}</a></td>
            <td>{{ listed["id"] }}</td>
            <td>{{ listed["email"] or '—' }}</td>
            <td>{{ listed["coins"] }}</td>
            <td>{{ listed["character_count"] }}</td>
            <td>
              {% if listed["is_web_admin"] %}<span class="pill">portal admin</span>{% endif %}
              {% if listed["online"] %}<span class="pill">online</span>{% endif %}
              {% if not listed["active"] %}<span class="pill">inactive</span>{% endif %}
              {% if listed["locked"] %}<span class="pill">locked</span>{% endif %}
            </td>
            <td>
              <form method="post" action="{{ url_for('reset_account_password') }}" class="inline-form" style="margin-bottom: 8px;">
                <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                <input type="hidden" name="account_id" value="{{ listed['id'] }}">
                <input type="hidden" name="query" value="{{ query }}">
                <input type="password" name="password" maxlength="16" placeholder="New password" required>
                <button type="submit">Reset password</button>
              </form>
              <form method="post" action="{{ url_for('delete_empty_account') }}" class="inline-form">
                <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                <input type="hidden" name="account_id" value="{{ listed['id'] }}">
                <input type="hidden" name="query" value="{{ query }}">
                <button class="warn" type="submit" {% if listed["character_count"] or listed["online"] or listed["id"] == current_user["id"] %}disabled{% endif %}>Delete empty account</button>
              </form>
            </td>
          </tr>
        {% endfor %}
      </tbody>
    </table>
  {% else %}
    <p class="muted">No accounts matched that filter.</p>
  {% endif %}
</section>

{% if account %}
  <section class="card" style="margin-top: 16px;">
    <h2>Account: {{ account["username"] }}</h2>
    <p>
      ID {{ account["id"] }}
      · rank {{ account["rank"] }}
      · shop coins {{ account["coins"] }}
      {% if account["email"] %}· {{ account["email"] }}{% endif %}
    </p>
    <form method="post" action="{{ url_for('update_coins') }}" class="inline-form">
      <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
      <input type="hidden" name="account_id" value="{{ account['id'] }}">
      <input type="hidden" name="query" value="{{ query }}">
      <input type="number" name="coins" value="{{ account['coins'] }}" required>
      <button type="submit">Set shop coins</button>
    </form>
  </section>

  <section class="card" style="margin-top: 16px;">
    <h2>Characters</h2>
    {% if characters %}
      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Class</th>
            <th>Realm DB</th>
            <th>Level</th>
            <th>Money</th>
            <th>State</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {% for character in characters %}
            <tr>
              <td>{{ character.name }}</td>
              <td>{{ character.class_name }}</td>
              <td>{{ character.database }}</td>
              <td>{{ character.level }}</td>
              <td>{{ character.money_display }}</td>
              <td>{% if character.online %}<span class="pill">online</span>{% else %}<span class="pill">offline</span>{% endif %}</td>
              <td>
                {% if character.online %}
                  <span class="muted">Offline only</span>
                {% else %}
                  <form method="post" action="{{ url_for('boost_character') }}" class="inline-form" style="margin-bottom: 8px;">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                    <input type="hidden" name="database" value="{{ character.database }}">
                    <input type="hidden" name="guid" value="{{ character.guid }}">
                    <input type="hidden" name="query" value="{{ query }}">
                    <button class="warn" type="submit">Boost Turtle max + test gold</button>
                  </form>
                  <form method="post" action="{{ url_for('mail_t1_preset') }}" class="inline-form" style="margin-bottom: 8px;">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                    <input type="hidden" name="database" value="{{ character.database }}">
                    <input type="hidden" name="guid" value="{{ character.guid }}">
                    <input type="hidden" name="query" value="{{ query }}">
                    <button class="secondary" type="submit">Mail T1 + trinkets</button>
                  </form>
                  <form method="post" action="{{ url_for('apply_character_loadout') }}" class="inline-form" style="margin-bottom: 8px;">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                    <input type="hidden" name="database" value="{{ character.database }}">
                    <input type="hidden" name="guid" value="{{ character.guid }}">
                    <input type="hidden" name="query" value="{{ query }}">
                    <select name="preset" required>
                      {% for value, label in loadout_options %}
                        <option value="{{ value }}">{{ label }}</option>
                      {% endfor %}
                    </select>
                    <button class="secondary" type="submit">Apply loadout</button>
                  </form>
                  <form method="post" action="{{ url_for('update_character') }}" class="inline-form">
                    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
                    <input type="hidden" name="database" value="{{ character.database }}">
                    <input type="hidden" name="guid" value="{{ character.guid }}">
                    <input type="hidden" name="query" value="{{ query }}">
                    <input type="number" name="level" min="1" max="60" value="{{ character.level }}" required>
                    <input type="number" name="money" min="0" max="2147483647" value="{{ character.money }}" required>
                    <button type="submit">Save level / money</button>
                  </form>
                {% endif %}
              </td>
            </tr>
          {% endfor %}
        </tbody>
      </table>
    {% else %}
      <p class="muted">No characters found for this account in the configured character databases.</p>
    {% endif %}
  </section>
{% elif query %}
  <section class="card" style="margin-top: 16px;">
    <p class="muted">No exact account matched that username for character detail.</p>
  </section>
{% endif %}
"""


@dataclass
class CharacterRow:
    database: str
    realm_id: int | None
    guid: int
    name: str
    class_id: int
    level: int
    money: int
    online: int

    @property
    def money_display(self) -> str:
        gold = self.money // 10000
        silver = (self.money % 10000) // 100
        copper = self.money % 100
        return f"{gold}g {silver}s {copper}c"

    @property
    def class_name(self) -> str:
        return CLASS_LABELS.get(self.class_id, f"Class {self.class_id}")


def normalize_credential(value: str) -> str:
    return value.upper()


def sha_pass_hash(username: str, password: str) -> str:
    normalized_user = normalize_credential(username)
    normalized_pass = normalize_credential(password)
    payload = f"{normalized_user}:{normalized_pass}".encode("utf-8")
    return hashlib.sha1(payload).hexdigest().upper()


def validate_account_inputs(username: str, password: str) -> tuple[bool, str]:
    if not ACCOUNT_RE.fullmatch(username):
        return False, "Username must be 3-16 characters using letters, numbers, or underscore."
    if not ACCOUNT_RE.fullmatch(password):
        return False, "Password must be 3-16 characters using letters, numbers, or underscore."
    return True, ""


def validate_password_input(password: str) -> tuple[bool, str]:
    if not ACCOUNT_RE.fullmatch(password):
        return False, "Password must be 3-16 characters using letters, numbers, or underscore."
    return True, ""


@contextmanager
def db(database: str):
    conn = pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=database,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def fetch_one(database: str, query: str, params: Iterable = ()) -> dict | None:
    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            return cur.fetchone()


def fetch_all(database: str, query: str, params: Iterable = ()) -> list[dict]:
    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            return list(cur.fetchall())


def ensure_auth_web_admins_table():
    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS auth_web_admins (
                    account_id INT UNSIGNED NOT NULL PRIMARY KEY,
                    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
                """
            )


def render_page(title: str, body: str, **context):
    return render_template_string(
        LAYOUT,
        title=title,
        body=render_template_string(body, current_user=g.current_user, **context),
        current_user=g.current_user,
    )


def ensure_csrf():
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_hex(16)
        session["csrf_token"] = token
    return token


def require_post_csrf():
    if session.get("csrf_token") != request.form.get("csrf_token"):
        abort(400)


def login_throttle_key(username: str) -> str:
    remote = request.headers.get("X-Forwarded-For", request.remote_addr or "unknown")
    normalized_user = normalize_credential(username) if username else ""
    return f"{remote}:{normalized_user}"


def prune_failed_logins(now: float):
    cutoff = now - LOGIN_THROTTLE_WINDOW_SECONDS
    expired_keys = []
    for key, attempts in FAILED_LOGIN_ATTEMPTS.items():
        FAILED_LOGIN_ATTEMPTS[key] = [attempt for attempt in attempts if attempt >= cutoff]
        if not FAILED_LOGIN_ATTEMPTS[key]:
            expired_keys.append(key)
    for key in expired_keys:
        FAILED_LOGIN_ATTEMPTS.pop(key, None)


def check_login_throttle(username: str) -> int | None:
    now = time.time()
    prune_failed_logins(now)
    key = login_throttle_key(username)
    attempts = FAILED_LOGIN_ATTEMPTS.get(key, [])
    if len(attempts) < LOGIN_THROTTLE_MAX_ATTEMPTS:
        return None
    retry_after = int(LOGIN_THROTTLE_WINDOW_SECONDS - (now - attempts[0]))
    return max(retry_after, 1)


def register_failed_login(username: str):
    now = time.time()
    prune_failed_logins(now)
    key = login_throttle_key(username)
    attempts = FAILED_LOGIN_ATTEMPTS.setdefault(key, [])
    attempts.append(now)


def clear_failed_logins(username: str):
    FAILED_LOGIN_ATTEMPTS.pop(login_throttle_key(username), None)


def login_account(username: str, password: str) -> dict | None:
    normalized_user = normalize_credential(username)
    row = fetch_one(
        LOGIN_DB,
        """
        SELECT
            a.id,
            a.username,
            a.rank,
            a.email,
            a.sha_pass_hash,
            CASE WHEN awa.account_id IS NULL THEN 0 ELSE 1 END AS is_web_admin
        FROM account a
        LEFT JOIN auth_web_admins awa ON awa.account_id = a.id
        WHERE a.username = %s
        """,
        (normalized_user,),
    )
    if not row:
        return None
    if row["sha_pass_hash"] != sha_pass_hash(username, password):
        return None
    return row


def account_has_admins() -> bool:
    ensure_auth_web_admins_table()
    row = fetch_one(LOGIN_DB, "SELECT 1 AS present FROM auth_web_admins LIMIT 1")
    return bool(row)


def resolve_realm_id_for_character_db(database: str) -> int | None:
    slug = database
    if slug.endswith("characters"):
        slug = slug[: -len("characters")]
    slug = slug.lower()

    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id, name FROM realmlist ORDER BY id ASC")
            for row in cur.fetchall():
                if slug and slug in row["name"].lower():
                    return int(row["id"])
    return None


def resolve_world_db_for_character_db(database: str) -> str | None:
    if database not in CHARACTER_DBS:
        return None
    if database.endswith("characters"):
        candidate = f"{database[:-len('characters')]}world"
    else:
        candidate = f"{database}_world"
    if DB_NAME_RE.fullmatch(candidate):
        return candidate
    return None


def queue_pending_command(realm_id: int, command: str):
    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO pending_commands(realm_id, command, run_at_time)
                VALUES (%s, %s, %s)
                """,
                (realm_id, command, int(time.time())),
            )


def loadout_label(preset: str) -> str:
    for value, label in LOADOUT_OPTIONS:
        if value == preset:
            return label
    return preset


def loadout_target_level(preset: str) -> int | None:
    if preset.startswith("level"):
        return int(preset[len("level") :])
    if preset in TIER_FILLER_CAPS:
        return 60
    return None


def fetch_item_template(database: str, entry: int) -> dict | None:
    return fetch_one(
        database,
        """
        SELECT entry, name, inventory_type, subclass, item_level, required_level, quality, max_durability
        FROM item_template
        WHERE entry = %s
        """,
        (entry,),
    )


def next_item_instance_guid(cur) -> int:
    cur.execute("SELECT COALESCE(MAX(guid), 0) + 1 AS next_guid FROM item_instance")
    return int(cur.fetchone()["next_guid"])


def delete_character_items(cur, guid: int, item_guids: list[int]):
    if not item_guids:
        return
    placeholders = ", ".join(["%s"] * len(item_guids))
    cur.execute(f"DELETE FROM character_inventory WHERE item IN ({placeholders})", item_guids)
    cur.execute(f"DELETE FROM item_instance WHERE guid IN ({placeholders})", item_guids)


def clear_replaced_loadout_slots(cur, guid: int):
    cur.execute(
        """
        SELECT item, slot
        FROM character_inventory
        WHERE guid = %s AND bag = %s AND slot BETWEEN 0 AND 22
        """,
        (guid, BACKPACK_CONTAINER_SLOT),
    )
    equipped_rows = cur.fetchall()
    root_item_guids = [int(row["item"]) for row in equipped_rows]
    bag_item_guids = [int(row["item"]) for row in equipped_rows if int(row["slot"]) in BAG_EQUIP_SLOTS]

    nested_item_guids: list[int] = []
    if bag_item_guids:
        placeholders = ", ".join(["%s"] * len(bag_item_guids))
        cur.execute(
            f"SELECT item FROM character_inventory WHERE bag IN ({placeholders})",
            bag_item_guids,
        )
        nested_item_guids = [int(row["item"]) for row in cur.fetchall()]

    delete_character_items(cur, guid, [*nested_item_guids, *root_item_guids])


def insert_equipped_item(cur, world_db: str, owner_guid: int, item_guid: int, bag: int, slot: int, entry: int):
    template = fetch_item_template(world_db, entry)
    if not template:
        raise ValueError(f"Missing item template {entry} in {world_db}.")
    cur.execute(
        """
        INSERT INTO item_instance(
            guid, itemEntry, owner_guid, creatorGuid, giftCreatorGuid, count, duration, charges,
            flags, enchantments, randomPropertyId, transmogrifyId, durability, text, generated_loot
        )
        VALUES (%s, %s, %s, 0, 0, 1, 0, '', 0, '', 0, 0, %s, 0, 0)
        """,
        (item_guid, entry, owner_guid, template["max_durability"]),
    )
    cur.execute(
        """
        INSERT INTO character_inventory(guid, bag, slot, item, item_template)
        VALUES (%s, %s, %s, %s, %s)
        """,
        (owner_guid, bag, slot, item_guid, entry),
    )


def query_best_item(
    world_db: str,
    class_id: int,
    inventory_types: tuple[int, ...],
    item_level_cap: int,
    exclude_entries: set[int],
    required_level_cap: int,
    armor_subclass: int | None = None,
    weapon_subclasses: tuple[int, ...] | None = None,
    name_like: str | None = None,
):
    class_mask = CLASS_MASKS[class_id]
    params: list[object] = [required_level_cap, item_level_cap]
    clauses = [
        "required_level <= %s",
        "item_level <= %s",
        "quality >= 2",
        "(allowable_class = -1 OR (allowable_class & %s) != 0)",
    ]
    params.append(class_mask)

    inv_placeholders = ", ".join(["%s"] * len(inventory_types))
    clauses.append(f"inventory_type IN ({inv_placeholders})")
    params.extend(inventory_types)

    if armor_subclass is not None:
        clauses.append("class = 4")
        clauses.append("subclass = %s")
        params.append(armor_subclass)

    if weapon_subclasses is not None:
        subclass_placeholders = ", ".join(["%s"] * len(weapon_subclasses))
        clauses.append("class = 2")
        clauses.append(f"subclass IN ({subclass_placeholders})")
        params.extend(weapon_subclasses)

    if exclude_entries:
        exclude_placeholders = ", ".join(["%s"] * len(exclude_entries))
        clauses.append(f"entry NOT IN ({exclude_placeholders})")
        params.extend(sorted(exclude_entries))

    if name_like:
        clauses.append("name LIKE %s")
        params.append(f"%{name_like}%")

    with db(world_db) as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT entry, name, inventory_type, subclass, item_level, required_level, quality, max_durability
                FROM item_template
                WHERE {' AND '.join(clauses)}
                ORDER BY item_level DESC, quality DESC, required_level DESC, entry ASC
                LIMIT 1
                """,
                params,
            )
            return cur.fetchone()


def build_dynamic_loadout(world_db: str, class_id: int, level: int, item_level_cap: int) -> dict[int, int]:
    loadout: dict[int, int] = {}
    used_entries: set[int] = set()
    armor_subclass = ARMOR_SUBCLASS_BY_CLASS.get(class_id)

    for slot_config in ARMOR_SLOT_CONFIGS:
        subclass = armor_subclass if slot_config["slot"] in {0, 2, 4, 5, 6, 7, 8, 9} else None
        item = query_best_item(
            world_db,
            class_id,
            slot_config["inventory_types"],
            item_level_cap,
            used_entries,
            level,
            armor_subclass=subclass,
        )
        if not item:
            continue
        entry = int(item["entry"])
        loadout[slot_config["slot"]] = entry
        used_entries.add(entry)

    for slot_plan in WEAPON_SLOT_PLANS.get(class_id, []):
        item = query_best_item(
            world_db,
            class_id,
            slot_plan["inventory_types"],
            item_level_cap,
            used_entries,
            level,
            weapon_subclasses=slot_plan["subclasses"],
        )
        if not item:
            continue
        entry = int(item["entry"])
        loadout[slot_plan["slot"]] = entry
        used_entries.add(entry)

    return loadout


def apply_tier_set(world_db: str, class_id: int, tier_name: str, base_loadout: dict[int, int]):
    token = TIER_TOKEN_BY_CLASS.get(class_id, {}).get(tier_name)
    if not token:
        return

    tier_slots = {0, 2, 4, 5, 6, 7, 8, 9}
    used_entries = set(base_loadout.values())
    armor_subclass = ARMOR_SUBCLASS_BY_CLASS.get(class_id)

    for slot_config in ARMOR_SLOT_CONFIGS:
        if slot_config["slot"] not in tier_slots:
            continue
        subclass = armor_subclass if slot_config["slot"] in {0, 2, 4, 5, 6, 7, 8, 9} else None
        item = query_best_item(
            world_db,
            class_id,
            slot_config["inventory_types"],
            TIER_FILLER_CAPS[tier_name],
            used_entries,
            60,
            armor_subclass=subclass,
            name_like=token,
        )
        if not item:
            continue
        entry = int(item["entry"])
        base_loadout[slot_config["slot"]] = entry
        used_entries.add(entry)


def apply_offline_loadout(database: str, guid: int, class_id: int, preset: str):
    world_db = resolve_world_db_for_character_db(database)
    if not world_db:
        raise ValueError("Could not resolve a world database for that character.")

    target_level = loadout_target_level(preset)
    if target_level is None:
        raise ValueError("Unknown loadout preset.")

    item_level_cap = TIER_FILLER_CAPS.get(preset, LOADOUT_ITEM_CAPS[target_level])
    loadout = build_dynamic_loadout(world_db, class_id, target_level, item_level_cap)
    if preset in TIER_FILLER_CAPS:
        apply_tier_set(world_db, class_id, preset, loadout)

    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE characters SET level = %s, xp = 0 WHERE guid = %s",
                (target_level, guid),
            )
            clear_replaced_loadout_slots(cur, guid)
            next_guid = next_item_instance_guid(cur)

            for slot in BAG_EQUIP_SLOTS:
                insert_equipped_item(cur, world_db, guid, next_guid, BACKPACK_CONTAINER_SLOT, slot, BAG_SLOT_ITEM)
                next_guid += 1

            for slot in sorted(loadout):
                insert_equipped_item(cur, world_db, guid, next_guid, BACKPACK_CONTAINER_SLOT, slot, loadout[slot])
                next_guid += 1


def can_bootstrap_admin() -> bool:
    return bool(BOOTSTRAP_ADMIN_KEY)


def create_account(username: str, password: str, email: str, bootstrap_admin_key: str) -> tuple[bool, str]:
    normalized_user = normalize_credential(username)
    normalized_pass = normalize_credential(password)
    make_web_admin = not account_has_admins()
    if make_web_admin:
        if not BOOTSTRAP_ADMIN_KEY:
            return False, "Portal admin bootstrap is disabled until AUTH_WEB_BOOTSTRAP_ADMIN_KEY is configured."
        if bootstrap_admin_key != BOOTSTRAP_ADMIN_KEY:
            return False, "Bootstrap admin key is required to create the first portal admin."
    account_hash = sha_pass_hash(normalized_user, normalized_pass)

    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS auth_web_admins (
                    account_id INT UNSIGNED NOT NULL PRIMARY KEY,
                    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
                """
            )
            cur.execute("SELECT id FROM account WHERE username = %s", (normalized_user,))
            if cur.fetchone():
                return False, "That username already exists."

            cur.execute(
                """
                INSERT INTO account(username, sha_pass_hash, rank, email, joindate)
                VALUES (%s, %s, %s, %s, NOW())
                """,
                (normalized_user, account_hash, 0, email or None),
            )
            account_id = cur.lastrowid
            if make_web_admin:
                cur.execute(
                    "INSERT INTO auth_web_admins(account_id) VALUES (%s)",
                    (account_id,),
                )
            cur.execute(
                "INSERT INTO shop_coins(id, coins) VALUES (%s, 0) ON DUPLICATE KEY UPDATE coins = coins",
                (account_id,),
            )
            cur.execute(
                """
                REPLACE INTO realmcharacters (realmid, acctid, numchars)
                SELECT realmlist.id, %s, 0 FROM realmlist
                """,
                (account_id,),
            )

    if make_web_admin:
        return True, "Account created. This first account was marked as a portal admin."
    return True, "Account created successfully."


def require_login():
    if not g.current_user:
        return redirect(url_for("login"))
    return None


def require_admin():
    if not g.current_user:
        return redirect(url_for("login"))
    if not g.current_user["is_web_admin"]:
        abort(403)
    return None


def current_user_row() -> dict | None:
    account_id = session.get("account_id")
    if not account_id:
        return None
    return fetch_one(
        LOGIN_DB,
        """
        SELECT
            a.id,
            a.username,
            a.rank,
            a.email,
            a.active,
            a.locked,
            CASE WHEN awa.account_id IS NULL THEN 0 ELSE 1 END AS is_web_admin
        FROM account a
        LEFT JOIN auth_web_admins awa ON awa.account_id = a.id
        WHERE a.id = %s
        """,
        (account_id,),
    )


def character_counts_for_accounts(account_ids: list[int]) -> dict[int, int]:
    counts = {account_id: 0 for account_id in account_ids}
    if not account_ids:
        return counts

    placeholders = ", ".join(["%s"] * len(account_ids))
    for database in CHARACTER_DBS:
        with db(database) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    f"""
                    SELECT account, COUNT(*) AS total
                    FROM characters
                    WHERE account IN ({placeholders})
                    GROUP BY account
                    """,
                    account_ids,
                )
                for row in cur.fetchall():
                    counts[int(row["account"])] = counts.get(int(row["account"]), 0) + int(row["total"])
    return counts


def load_account_list(query: str) -> list[dict]:
    normalized_query = normalize_credential(query) if query else ""
    params: list[object] = []
    where_clause = ""
    if normalized_query:
        where_clause = "WHERE a.username LIKE %s"
        params.append(f"%{normalized_query}%")

    accounts = fetch_all(
        LOGIN_DB,
        f"""
        SELECT
            a.id,
            a.username,
            a.rank,
            a.email,
            a.online,
            a.active,
            a.locked,
            COALESCE(sc.coins, 0) AS coins,
            CASE WHEN awa.account_id IS NULL THEN 0 ELSE 1 END AS is_web_admin
        FROM account a
        LEFT JOIN shop_coins sc ON sc.id = a.id
        LEFT JOIN auth_web_admins awa ON awa.account_id = a.id
        {where_clause}
        ORDER BY a.joindate DESC, a.id DESC
        LIMIT 100
        """,
        params,
    )

    counts = character_counts_for_accounts([int(account["id"]) for account in accounts])
    for account in accounts:
        account["character_count"] = counts.get(int(account["id"]), 0)
    return accounts


def load_account_summary_by_id(account_id: int) -> dict | None:
    account = fetch_one(
        LOGIN_DB,
        """
        SELECT
            a.id,
            a.username,
            a.rank,
            a.email,
            a.online,
            a.active,
            a.locked,
            COALESCE(sc.coins, 0) AS coins,
            CASE WHEN awa.account_id IS NULL THEN 0 ELSE 1 END AS is_web_admin
        FROM account a
        LEFT JOIN shop_coins sc ON sc.id = a.id
        LEFT JOIN auth_web_admins awa ON awa.account_id = a.id
        WHERE a.id = %s
        """,
        (account_id,),
    )
    if not account:
        return None
    account["character_count"] = character_counts_for_accounts([account_id]).get(account_id, 0)
    return account


def has_other_portal_admins(account_id: int) -> bool:
    row = fetch_one(
        LOGIN_DB,
        "SELECT 1 AS present FROM auth_web_admins WHERE account_id <> %s LIMIT 1",
        (account_id,),
    )
    return bool(row)


def load_account_details(username: str) -> tuple[dict | None, list[CharacterRow]]:
    account = fetch_one(
        LOGIN_DB,
        """
        SELECT
            a.id,
            a.username,
            a.rank,
            a.email,
            a.online,
            a.active,
            a.locked,
            COALESCE(sc.coins, 0) AS coins,
            CASE WHEN awa.account_id IS NULL THEN 0 ELSE 1 END AS is_web_admin
        FROM account a
        LEFT JOIN shop_coins sc ON sc.id = a.id
        LEFT JOIN auth_web_admins awa ON awa.account_id = a.id
        WHERE a.username = %s
        """,
        (normalize_credential(username),),
    )
    characters: list[CharacterRow] = []
    if not account:
        return None, characters

    for database in CHARACTER_DBS:
        with db(database) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT guid, name, class, level, money, online
                    FROM characters
                    WHERE account = %s
                    ORDER BY level DESC, name ASC
                    """,
                    (account["id"],),
                )
                realm_id = resolve_realm_id_for_character_db(database)
                for row in cur.fetchall():
                    characters.append(CharacterRow(database=database, realm_id=realm_id, class_id=row["class"], guid=row["guid"], name=row["name"], level=row["level"], money=row["money"], online=row["online"]))

    return account, characters


@app.before_request
def load_current_user():
    ensure_auth_web_admins_table()
    g.current_user = current_user_row()
    ensure_csrf()


@app.get("/")
def home():
    return render_page("SnapJaw Auth Portal", HOME_BODY)


@app.route("/register", methods=["GET", "POST"])
def register():
    if request.method == "POST":
        require_post_csrf()
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()
        email = request.form.get("email", "").strip()
        bootstrap_admin_key = request.form.get("bootstrap_admin_key", "").strip()
        valid, message = validate_account_inputs(username, password)
        if not valid:
            flash(message, "error")
        else:
            ok, message = create_account(username, password, email, bootstrap_admin_key)
            flash(message, "success" if ok else "error")
            if ok:
                return redirect(url_for("login"))

    return render_page(
        "Register",
        REGISTER_BODY,
        csrf_token=session["csrf_token"],
        login_db=LOGIN_DB,
        bootstrap_required=(not account_has_admins() and can_bootstrap_admin()),
    )


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        require_post_csrf()
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "").strip()
        retry_after = check_login_throttle(username)
        if retry_after is not None:
            flash(f"Too many login attempts. Try again in {retry_after} seconds.", "error")
            return render_page("Login", LOGIN_BODY, csrf_token=session["csrf_token"])
        user = login_account(username, password)
        if not user:
            register_failed_login(username)
            flash("Invalid username or password.", "error")
        else:
            clear_failed_logins(username)
            session["account_id"] = user["id"]
            flash("Signed in.", "success")
            return redirect(url_for("admin" if user["is_web_admin"] else "home"))

    return render_page("Login", LOGIN_BODY, csrf_token=session["csrf_token"])


@app.get("/logout")
def logout():
    session.clear()
    flash("Signed out.", "success")
    return redirect(url_for("home"))


@app.get("/admin")
def admin():
    failure = require_admin()
    if failure:
        return failure

    query = request.args.get("q", "").strip()
    accounts = load_account_list(query)
    account = None
    characters: list[CharacterRow] = []
    if query:
        account, characters = load_account_details(query)

    return render_page(
        "Admin",
        ADMIN_BODY,
        query=query,
        accounts=accounts,
        account=account,
        characters=characters,
        csrf_token=session["csrf_token"],
        loadout_options=LOADOUT_OPTIONS,
        level_boost=LEVEL_BOOST,
        money_boost_display=CharacterRow("", None, 0, "", 0, 0, MONEY_BOOST_COPPER, 0).money_display,
    )


@app.post("/admin/coins")
def update_coins():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    account_id = int(request.form["account_id"])
    coins = int(request.form["coins"])
    if coins < 0:
        flash("Coins cannot be negative.", "error")
        return redirect(url_for("admin"))

    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO shop_coins(id, coins) VALUES (%s, %s)
                ON DUPLICATE KEY UPDATE coins = VALUES(coins)
                """,
                (account_id, coins),
            )

    flash("Shop coin balance updated.", "success")
    return redirect(url_for("admin", q=request.form.get("query", "")))


@app.post("/admin/account/password")
def reset_account_password():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    account_id = int(request.form["account_id"])
    password = request.form.get("password", "").strip()
    query = request.form.get("query", "")

    account = load_account_summary_by_id(account_id)
    if not account:
        flash("Account not found.", "error")
        return redirect(url_for("admin", q=query))

    valid, message = validate_password_input(password)
    if not valid:
        flash(message, "error")
        return redirect(url_for("admin", q=query))

    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE account
                SET sha_pass_hash = %s, sessionkey = NULL, v = NULL, s = NULL, failed_logins = 0, locked = 0
                WHERE id = %s
                """,
                (sha_pass_hash(account["username"], password), account_id),
            )

    flash(f"Reset the password for {account['username']}.", "success")
    return redirect(url_for("admin", q=query or account["username"]))


@app.post("/admin/account/delete")
def delete_empty_account():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    account_id = int(request.form["account_id"])
    query = request.form.get("query", "")

    account = load_account_summary_by_id(account_id)
    if not account:
        flash("Account not found.", "error")
        return redirect(url_for("admin", q=query))

    if g.current_user and int(g.current_user["id"]) == account_id:
        flash("You cannot delete your own portal account.", "error")
        return redirect(url_for("admin", q=query or account["username"]))
    if account["online"]:
        flash("Only offline accounts can be deleted.", "error")
        return redirect(url_for("admin", q=query or account["username"]))
    if account["character_count"]:
        flash("Only empty accounts with no characters can be deleted from the portal.", "error")
        return redirect(url_for("admin", q=query or account["username"]))
    if account["is_web_admin"] and not has_other_portal_admins(account_id):
        flash("You cannot delete the last portal admin.", "error")
        return redirect(url_for("admin", q=query or account["username"]))

    with db(LOGIN_DB) as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM auth_web_admins WHERE account_id = %s", (account_id,))
            cur.execute("DELETE FROM shop_coins WHERE id = %s", (account_id,))
            cur.execute("DELETE FROM realmcharacters WHERE acctid = %s", (account_id,))
            cur.execute("DELETE FROM account WHERE id = %s", (account_id,))

    flash(f"Deleted empty account {account['username']}.", "success")
    return redirect(url_for("admin", q=query))


def ensure_offline_character(database: str, guid: int) -> CharacterRow | None:
    if database not in CHARACTER_DBS:
        return None
    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT guid, name, class, level, money, online FROM characters WHERE guid = %s",
                (guid,),
            )
            row = cur.fetchone()
            if not row or row["online"]:
                return None
            return CharacterRow(
                database=database,
                realm_id=resolve_realm_id_for_character_db(database),
                class_id=row["class"],
                guid=row["guid"],
                name=row["name"],
                level=row["level"],
                money=row["money"],
                online=row["online"],
            )


def pending_command_safe_name(character: CharacterRow) -> str | None:
    if PENDING_COMMAND_NAME_RE.fullmatch(character.name):
        return character.name
    return None


@app.post("/admin/character")
def update_character():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    database = request.form["database"]
    guid = int(request.form["guid"])
    level = int(request.form["level"])
    money = int(request.form["money"])
    query = request.form.get("query", "")

    character = ensure_offline_character(database, guid)
    if not character:
        flash("Character must be offline and in a configured database.", "error")
        return redirect(url_for("admin", q=query))

    level = max(1, min(60, level))
    money = max(0, min(2147483647, money))

    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE characters SET level = %s, xp = 0, money = %s WHERE guid = %s",
                (level, money, guid),
            )

    flash(f"Updated {character.name}.", "success")
    return redirect(url_for("admin", q=query))


@app.post("/admin/character/loadout")
def apply_character_loadout():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    database = request.form["database"]
    guid = int(request.form["guid"])
    preset = request.form.get("preset", "").strip()
    query = request.form.get("query", "")

    character = ensure_offline_character(database, guid)
    if not character:
        flash("Character must be offline and in a configured database.", "error")
        return redirect(url_for("admin", q=query))

    if preset not in {value for value, _label in LOADOUT_OPTIONS}:
        flash("Unknown loadout preset.", "error")
        return redirect(url_for("admin", q=query))

    try:
        apply_offline_loadout(database, guid, character.class_id, preset)
    except ValueError as exc:
        flash(str(exc), "error")
        return redirect(url_for("admin", q=query))

    flash(f"Applied {loadout_label(preset)} to {character.name}.", "success")
    return redirect(url_for("admin", q=query))


@app.post("/admin/character/boost")
def boost_character():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    database = request.form["database"]
    guid = int(request.form["guid"])
    query = request.form.get("query", "")

    character = ensure_offline_character(database, guid)
    if not character:
        flash("Character must be offline and in a configured database.", "error")
        return redirect(url_for("admin", q=query))

    boosted_money = max(character.money, MONEY_BOOST_COPPER)
    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE characters SET level = %s, xp = 0, money = %s WHERE guid = %s",
                (LEVEL_BOOST, boosted_money, guid),
            )

    flash(f"Applied the test boost to {character.name}.", "success")
    return redirect(url_for("admin", q=query))


@app.post("/admin/character/preset")
def mail_t1_preset():
    failure = require_admin()
    if failure:
        return failure
    require_post_csrf()

    database = request.form["database"]
    guid = int(request.form["guid"])
    query = request.form.get("query", "")

    character = ensure_offline_character(database, guid)
    if not character:
        flash("Character must be offline and in a configured database.", "error")
        return redirect(url_for("admin", q=query))

    if character.realm_id is None:
        flash("Could not resolve the realm for that character database.", "error")
        return redirect(url_for("admin", q=query))

    t1_items = CLASS_T1_ITEMS.get(character.class_id)
    if not t1_items:
        flash(f"No Tier 1 preset is configured yet for {character.class_name}.", "error")
        return redirect(url_for("admin", q=query))

    safe_name = pending_command_safe_name(character)
    if safe_name is None:
        flash("Character name contains unsupported characters for queued mail commands.", "error")
        return redirect(url_for("admin", q=query))

    boosted_money = max(character.money, MONEY_BOOST_COPPER)
    with db(database) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE characters SET level = %s, xp = 0, money = %s WHERE guid = %s",
                (LEVEL_BOOST, boosted_money, guid),
            )

    item_tokens = " ".join(str(item_id) for item_id in [*t1_items, *T1_TRINKET_ITEMS])
    queue_pending_command(
        character.realm_id,
        f'send items {safe_name} "SnapJaw Test Gear" "Tier 1 test preset from the auth portal." {item_tokens}',
    )

    flash(
        f"Queued a Tier 1 test package for {character.name} and boosted the character to Turtle max.",
        "success",
    )
    return redirect(url_for("admin", q=query))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=WEB_PORT)
