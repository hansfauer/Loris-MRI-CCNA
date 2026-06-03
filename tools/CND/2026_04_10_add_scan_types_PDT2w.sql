-- =============================================================================
-- Option A: Split dual-echo PDT2 into two LORIS scan types (no Python changes).
-- Echo 1 -> anat-PDT2w_PD  (BIDS PDw), Echo 2 -> anat-PDT2w_T2 (BIDS T2w).
-- =============================================================================
--
-- How protocol matching works (python/lib/imaging.py look_for_matching_protocols):
--   - If mri_protocol.series_description_regex is NON-NULL/non-empty, ONLY the
--     regex is used; EchoNumber on that row is IGNORED for matching.
--   - To use EchoNumber, the cloned rows must have series_description_regex = NULL
--     (empty) so matching uses is_scan_protocol_matching_db_protocol (TE/TR/etc + EchoNumber).
--
-- Schema note: aligned to hauer_dev (database_config.py) — mri_protocol has
-- CenterID, ScannerID, *_range columns, no SeriesDescription; EchoNumber is varchar.
--
-- Steps:
--   1) If your DB differs, run SHOW COLUMNS FROM mri_protocol; and adjust lists.
--   2) Backup mri_protocol / bids_mri_scan_type_rel.
--   3) Run this script (or paste sections).
--   4) Remove BIDS rel rows that used BIDSEchoNumber on a single anat-PDT2w row
--      if you added those for Option B.
--
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Two new scan types (adjust names if they clash with your DB)
-- -----------------------------------------------------------------------------
INSERT INTO mri_scan_type (Scan_type)
SELECT 'anat-PDT2w_PD' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_PD');

INSERT INTO mri_scan_type (Scan_type)
SELECT 'anat-PDT2w_T2' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_T2');

-- -----------------------------------------------------------------------------
-- 2) Clone mri_protocol from existing anat-PDT2w -> two rows with EchoNumber 1 and 2
--    IMPORTANT: set series_description_regex to NULL so EchoNumber is used (see header).
--    EchoNumber is varchar(20) in hauer_dev; use '1' / '2' for int() matching in Python.
-- -----------------------------------------------------------------------------
-- Echo 1 -> PD-weighted volume
INSERT INTO mri_protocol (
    CenterID,
    ScannerID,
    Scan_type,
    TR_min,
    TR_max,
    TE_min,
    TE_max,
    TI_min,
    TI_max,
    slice_thickness_min,
    slice_thickness_max,
    xspace_min,
    xspace_max,
    yspace_min,
    yspace_max,
    zspace_min,
    zspace_max,
    xstep_min,
    xstep_max,
    ystep_min,
    ystep_max,
    zstep_min,
    zstep_max,
    time_min,
    time_max,
    TR_range,
    TE_range,
    TI_range,
    slice_thickness_range,
    xspace_range,
    yspace_range,
    zspace_range,
    xstep_range,
    ystep_range,
    zstep_range,
    time_range,
    series_description_regex,
    image_type,
    MriProtocolGroupID,
    PhaseEncodingDirection,
    EchoNumber
)
SELECT
    src.CenterID,
    src.ScannerID,
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_PD'),
    src.TR_min,
    src.TR_max,
    src.TE_min,
    src.TE_max,
    src.TI_min,
    src.TI_max,
    src.slice_thickness_min,
    src.slice_thickness_max,
    src.xspace_min,
    src.xspace_max,
    src.yspace_min,
    src.yspace_max,
    src.zspace_min,
    src.zspace_max,
    src.xstep_min,
    src.xstep_max,
    src.ystep_min,
    src.ystep_max,
    src.zstep_min,
    src.zstep_max,
    src.time_min,
    src.time_max,
    src.TR_range,
    src.TE_range,
    src.TI_range,
    src.slice_thickness_range,
    src.xspace_range,
    src.yspace_range,
    src.zspace_range,
    src.xstep_range,
    src.ystep_range,
    src.zstep_range,
    src.time_range,
    NULL,
    src.image_type,
    src.MriProtocolGroupID,
    src.PhaseEncodingDirection,
    '1'
FROM mri_protocol AS src
JOIN mri_scan_type AS mst ON src.Scan_type = mst.ID
WHERE mst.Scan_type = 'anat-PDT2w'
LIMIT 1;

-- Echo 2 -> T2-weighted volume (same geometry, different echo index)
INSERT INTO mri_protocol (
    CenterID,
    ScannerID,
    Scan_type,
    TR_min,
    TR_max,
    TE_min,
    TE_max,
    TI_min,
    TI_max,
    slice_thickness_min,
    slice_thickness_max,
    xspace_min,
    xspace_max,
    yspace_min,
    yspace_max,
    zspace_min,
    zspace_max,
    xstep_min,
    xstep_max,
    ystep_min,
    ystep_max,
    zstep_min,
    zstep_max,
    time_min,
    time_max,
    TR_range,
    TE_range,
    TI_range,
    slice_thickness_range,
    xspace_range,
    yspace_range,
    zspace_range,
    xstep_range,
    ystep_range,
    zstep_range,
    time_range,
    series_description_regex,
    image_type,
    MriProtocolGroupID,
    PhaseEncodingDirection,
    EchoNumber
)
SELECT
    src.CenterID,
    src.ScannerID,
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_T2'),
    src.TR_min,
    src.TR_max,
    src.TE_min,
    src.TE_max,
    src.TI_min,
    src.TI_max,
    src.slice_thickness_min,
    src.slice_thickness_max,
    src.xspace_min,
    src.xspace_max,
    src.yspace_min,
    src.yspace_max,
    src.zspace_min,
    src.zspace_max,
    src.xstep_min,
    src.xstep_max,
    src.ystep_min,
    src.ystep_max,
    src.zstep_min,
    src.zstep_max,
    src.time_min,
    src.time_max,
    src.TR_range,
    src.TE_range,
    src.TI_range,
    src.slice_thickness_range,
    src.xspace_range,
    src.yspace_range,
    src.zspace_range,
    src.xstep_range,
    src.ystep_range,
    src.zstep_range,
    src.time_range,
    NULL,
    src.image_type,
    src.MriProtocolGroupID,
    src.PhaseEncodingDirection,
    '2'
FROM mri_protocol AS src
JOIN mri_scan_type AS mst ON src.Scan_type = mst.ID
WHERE mst.Scan_type = 'anat-PDT2w'
LIMIT 1;

-- -----------------------------------------------------------------------------
-- 3) Remove the OLD protocol row(s) for anat-PDT2w so only echo-specific rows match.
--    Otherwise both echoes can still match the old row -> "more than one protocol matched".
-- -----------------------------------------------------------------------------
DELETE mp FROM mri_protocol AS mp
JOIN mri_scan_type AS mst ON mp.Scan_type = mst.ID
WHERE mst.Scan_type = 'anat-PDT2w';

-- Optional: keep mri_scan_type 'anat-PDT2w' for historical File rows, or delete if unused:
-- DELETE FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w';

-- -----------------------------------------------------------------------------
-- 4) BIDS: one bids_mri_scan_type_rel per new scan type; BIDSEchoNumber NULL.
--    Shared acquisition label acq-PDT2w on both echoes (via bids_scan_type_subcategory).
-- -----------------------------------------------------------------------------
INSERT INTO bids_scan_type (BIDSScanType)
SELECT 'PDw' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'PDw');

INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'acq-PDT2w' FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'acq-PDT2w'
);

INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT
    mst.ID,
    bc.BIDSCategoryID,
    bst.BIDSScanTypeID,
    bss.BIDSScanTypeSubCategoryID,
    NULL
FROM mri_scan_type AS mst
CROSS JOIN bids_category AS bc
CROSS JOIN bids_scan_type AS bst
CROSS JOIN bids_scan_type_subcategory AS bss
WHERE mst.Scan_type = 'anat-PDT2w_PD'
  AND bc.BIDSCategoryName = 'anat'
  AND bst.BIDSScanType = 'PDw'
  AND bss.BIDSScanTypeSubCategory = 'acq-PDT2w'
  AND NOT EXISTS (
      SELECT 1 FROM bids_mri_scan_type_rel AS r
      WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber IS NULL
  );

INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT
    mst.ID,
    bc.BIDSCategoryID,
    bst.BIDSScanTypeID,
    bss.BIDSScanTypeSubCategoryID,
    NULL
FROM mri_scan_type AS mst
CROSS JOIN bids_category AS bc
CROSS JOIN bids_scan_type AS bst
CROSS JOIN bids_scan_type_subcategory AS bss
WHERE mst.Scan_type = 'anat-PDT2w_T2'
  AND bc.BIDSCategoryName = 'anat'
  AND bst.BIDSScanType = 'T2w'
  AND bss.BIDSScanTypeSubCategory = 'acq-PDT2w'
  AND NOT EXISTS (
      SELECT 1 FROM bids_mri_scan_type_rel AS r
      WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber IS NULL
  );

-- -----------------------------------------------------------------------------
-- 5) Verify
-- -----------------------------------------------------------------------------
-- SELECT mst.Scan_type, mp.EchoNumber, mp.series_description_regex
-- FROM mri_protocol mp JOIN mri_scan_type mst ON mp.Scan_type = mst.ID
-- WHERE mst.Scan_type IN ('anat-PDT2w_PD','anat-PDT2w_T2','anat-PDT2w');
