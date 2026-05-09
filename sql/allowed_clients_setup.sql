DROP TABLE IF EXISTS `allowed_clients`;

CREATE TABLE `allowed_clients` (
  `build` smallint(5) unsigned NOT NULL,
  `major_version` tinyint(3) unsigned NOT NULL,
  `minor_version` tinyint(3) unsigned NOT NULL,
  `bugfix_version` tinyint(3) unsigned NOT NULL,
  `hotfix_version` tinyint(3) unsigned NOT NULL DEFAULT 0,
  `platform` varchar(8) NOT NULL DEFAULT '',
  `os` varchar(8) NOT NULL DEFAULT '',
  `windows_hash` char(40) DEFAULT NULL,
  `mac_hash` char(40) DEFAULT NULL,
  `enabled` tinyint(3) unsigned NOT NULL DEFAULT 1,
  PRIMARY KEY (`build`,`platform`,`os`),
  KEY `idx_enabled` (`enabled`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci ROW_FORMAT=DYNAMIC COMMENT='Allowed client build metadata';

INSERT INTO `allowed_clients` (`build`, `major_version`, `minor_version`, `bugfix_version`, `hotfix_version`, `platform`, `os`, `windows_hash`, `mac_hash`, `enabled`) VALUES
  (7200, 1, 17, 2, 0, '', '', NULL, NULL, 1),
  (7205, 1, 17, 2, 0, '', '', NULL, NULL, 1),
  (7207, 1, 17, 2, 0, '', '', NULL, NULL, 1),
  (7234, 1, 18, 0, 0, '', '', NULL, NULL, 1),
  (7272, 1, 18, 1, 0, '', '', NULL, NULL, 1);
