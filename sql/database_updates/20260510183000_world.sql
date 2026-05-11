UPDATE `shop_items`
SET `price` = GREATEST(5, CEIL(`price` * 0.15))
WHERE `category` IN (1, 2, 7, 8);

UPDATE `shop_items`
SET `price` = GREATEST(6, CEIL(`price` * 0.20))
WHERE `category` IN (3, 4, 6);

UPDATE `shop_items`
SET `price` = GREATEST(8, CEIL(`price` * 0.12))
WHERE `category` = 5;
