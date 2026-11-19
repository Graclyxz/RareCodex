from pathlib import Path

from sqldump import SqlDump, parse_tuples

DUMP = """\
CREATE TABLE `npc` (
  `id` int NOT NULL,
  `name` varchar(50),
  `chance` float,
  PRIMARY KEY (`id`)
) ENGINE=MyISAM;
INSERT INTO `npc` VALUES (1,'Old \\'Grizzle\\'',2.5),(2,NULL,-1);
CREATE TABLE IF NOT EXISTS `other` (
  `a` int
) ENGINE=InnoDB;
INSERT INTO `npc` (`id`, `name`, `chance`) VALUES
  (3, 'It''s, (tricky)', 0);
"""


def test_parse_tuples_handles_escapes_and_nulls() -> None:
    rows, end = parse_tuples("(1,'a\\'b',NULL),(2, 'c,d', 1.5);rest", 0)
    assert rows == [[1, "a'b", None], [2, "c,d", 1.5]]
    assert end == len("(1,'a\\'b',NULL),(2, 'c,d', 1.5);")


def test_sqldump_reads_selected_tables(tmp_path: Path) -> None:
    path = tmp_path / "dump.sql"
    path.write_text(DUMP, encoding="utf-8")
    db = SqlDump(path, {"npc"})
    assert db.columns["npc"] == ["id", "name", "chance"]
    assert list(db.rows("npc")) == [
        {"id": 1, "name": "Old 'Grizzle'", "chance": 2.5},
        {"id": 2, "name": None, "chance": -1},
        {"id": 3, "name": "It's, (tricky)", "chance": 0},
    ]
