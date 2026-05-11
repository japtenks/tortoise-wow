DROP TABLE IF EXISTS `shop_achievement_credit_rewards`;

CREATE TABLE IF NOT EXISTS `shop_quest_credit_rewards` (
  `account_id` int(10) unsigned NOT NULL,
  `quest_id` int(10) unsigned NOT NULL,
  `character_guid` int(10) unsigned NOT NULL DEFAULT 0,
  `credits` int(10) unsigned NOT NULL DEFAULT 0,
  `rewarded_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`account_id`, `quest_id`) USING BTREE,
  KEY `idx_quest_id` (`quest_id`) USING BTREE,
  KEY `idx_character_guid` (`character_guid`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC;

CREATE TABLE IF NOT EXISTS `shop_quest_credit_milestones` (
  `account_id` int(10) unsigned NOT NULL,
  `milestone_quests` int(10) unsigned NOT NULL,
  `character_guid` int(10) unsigned NOT NULL DEFAULT 0,
  `credits` int(10) unsigned NOT NULL DEFAULT 0,
  `awarded_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`account_id`, `milestone_quests`) USING BTREE,
  KEY `idx_character_guid` (`character_guid`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC;
