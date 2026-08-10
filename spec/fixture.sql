-- A statistics database shaped exactly like KOReader's, holding one book read across
-- three evenings. The md5 is the document digest, which is how the plugin finds the
-- book its reader has open.
CREATE TABLE IF NOT EXISTS book (
    id integer PRIMARY KEY autoincrement,
    title text,
    authors text,
    notes integer,
    last_open integer,
    highlights integer,
    pages integer,
    series text,
    language text,
    md5 text,
    total_read_time integer,
    total_read_pages integer
);

CREATE TABLE IF NOT EXISTS page_stat_data (
    id_book integer,
    page integer NOT NULL DEFAULT 0,
    start_time integer NOT NULL DEFAULT 0,
    duration integer NOT NULL DEFAULT 0,
    total_pages integer NOT NULL DEFAULT 0,
    UNIQUE (id_book, page, start_time),
    FOREIGN KEY(id_book) REFERENCES book(id)
);

INSERT INTO book (title, authors, pages, md5, total_read_time, total_read_pages)
VALUES ('Toll the Hounds', 'Steven Erikson', 1280, :digest, 5400, 120);

-- Three evenings, an hour apart, at a steady forty seconds a page.
INSERT INTO page_stat_data (id_book, page, start_time, duration, total_pages)
WITH RECURSIVE turn(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM turn WHERE n < 120)
SELECT 1,
       n,
       CAST(strftime('%s', 'now', '-' || (3 - ((n - 1) / 40)) || ' days', 'start of day', '+20 hours') AS INTEGER) + ((n % 40) * 45),
       40,
       1280
FROM turn;
