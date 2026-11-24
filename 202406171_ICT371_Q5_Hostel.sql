-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL

DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path = q5_hostel, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('202406171', 'Clement Mwitwa'),
    ('202406172', 'Mary Banda'),
    ('202406173', 'Peter Phiri'),
    ('202406174', 'Linda Mulenga'),
    ('202406175', 'Kelvin Zimba');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),    -- will be FULL
    ('A102', 3),    -- will be PARTLY occupied
    ('A103', 2);    -- will be EMPTY (only ended history)

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_cap    INTEGER;
    v_active INTEGER;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';
    RETURN v_cap - v_active;       -- ENDED rows are never counted
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'allocated_on must not be NULL';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- serialise allocations per room
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_cap    INTEGER;
    v_others INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Lock the room so concurrent direct inserts cannot both take the last bed.
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

        IF EXISTS (SELECT 1 FROM allocations
                   WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                     AND allocation_id <> NEW.allocation_id) THEN        -- exclude the row being updated
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT COUNT(*) INTO v_others FROM allocations
        WHERE room_id = NEW.room_id AND status = 'ACTIVE'
          AND allocation_id <> NEW.allocation_id;                        -- exclude the row being updated
        IF v_others >= v_cap THEN
            RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

/* ---- (a) continued: allocations showing full, partly occupied and empty rooms ---- */
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- A101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 25);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);   -- A102 partly (1/3)
-- ENDED history (direct SQL; they do not occupy beds). A103 stays empty.
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED'),
    (5, 1, CURRENT_DATE - 80, CURRENT_DATE - 35, 'ENDED');

SELECT fn_free_beds(1) AS a101_free, fn_free_beds(2) AS a102_free, fn_free_beds(3) AS a103_free;  -- 0, 2, 2
DO $$ BEGIN PERFORM fn_free_beds(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Procedure rejections
DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);        -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);        -- student 1 already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
CALL pr_allocate_room(4, 2, CURRENT_DATE);                    -- valid: Linda into partly occupied A102 (A103 stays empty)

-- Trigger rejections for DIRECT SQL
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;   -- over capacity
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 2, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;   -- 2nd active for student 1
-- UPDATE excluding itself: closing then re-saving an allocation works
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE student_id = 4 AND status = 'ACTIVE';
UPDATE allocations SET status = 'ACTIVE', released_on = NULL WHERE student_id = 4 AND room_id = 2 AND status = 'ENDED' AND released_on = CURRENT_DATE;

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'   -- LEFT JOIN keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

/* ===================== (f) Index ===================== */
-- Justification: capacity checks, fn_free_beds and the occupancy view only ever count ACTIVE
-- rows per room. A PARTIAL index on room_id WHERE status = 'ACTIVE' is small (history is
-- excluded) and exactly matches that filter.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE      -- one row per date+room; rerun replaces values
        SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 23:55 (pg_cron time zone).
SELECT cron.schedule('q5_refresh_occupancy_daily', '55 23 * * *',
                     $$CALL q5_hostel.pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: same 3 rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q5_refresh_occupancy_daily';
