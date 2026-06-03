-- =============================================================================
-- Patch: Add series_description_regex to fmri_task_memory mri_protocol row.
--
-- Problem:
--   The fmri_task_memory row in mri_protocol has series_description_regex = NULL,
--   so it matches purely on TR/TE/geometry ranges. At sites where resting-state
--   scans (e.g. "func_task-rest Yeux Ouverts") have overlapping parameter ranges,
--   they are misclassified as fmri_task_memory because that row is evaluated
--   before the func_task-rest row (which has a correct regex) in the loop.
--
-- Fix:
--   Set series_description_regex on fmri_task_memory so it ONLY matches when
--   the series description contains "memory" (case-insensitive in both Perl
--   and Python matchers). This prevents resting-state or any other functional
--   scan from being absorbed by this row's geometry ranges.
--
-- Behaviour after patch:
--   - Perl:   $series_description =~ /memory/i
--   - Python: re.search(r"memory", SeriesDescription, re.IGNORECASE)
--   Both require the literal substring "memory" somewhere in the description.
--
-- Prerequisites: backup mri_protocol before running.
-- Run: mysql -h <host> -u <user> -p <database> < Patch_fmri_task_memory_regex.sql
-- =============================================================================

UPDATE mri_protocol
SET series_description_regex = 'MemoryTask'
WHERE Scan_type = (
    SELECT ID FROM mri_scan_type WHERE Scan_type = 'fmri_task_memory'
)
AND (series_description_regex IS NULL OR series_description_regex = '');

-- -------------------------------------------------------------------------
-- Verify the change
-- -------------------------------------------------------------------------
-- SELECT
--   mp.ID,
--   mst.Scan_type,
--   mp.series_description_regex,
--   mp.TR_min, mp.TR_max,
--   mp.TE_min, mp.TE_max
-- FROM mri_protocol mp
-- JOIN mri_scan_type mst ON mst.ID = mp.Scan_type
-- WHERE mst.Scan_type IN ('fmri_task_memory', 'func_task-rest');
