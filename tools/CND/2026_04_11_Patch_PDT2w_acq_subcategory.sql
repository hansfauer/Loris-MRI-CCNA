-- Add BIDS subcategory acq-PDT2w to existing anat-PDT2w_PD / anat-PDT2w_T2 rel rows.
-- Run: mysql -h ... -u ... -p hauer_dev < Patch_PDT2w_acq_subcategory.sql

INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'acq-PDT2w' FROM DUAL
WHERE NOT EXISTS (
    SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'acq-PDT2w'
);

UPDATE bids_mri_scan_type_rel AS bmstr
INNER JOIN mri_scan_type AS mst ON bmstr.MRIScanTypeID = mst.ID
INNER JOIN bids_scan_type_subcategory AS bss
    ON bss.BIDSScanTypeSubCategory = 'acq-PDT2w'
SET bmstr.BIDSScanTypeSubCategoryID = bss.BIDSScanTypeSubCategoryID
WHERE mst.Scan_type IN ('anat-PDT2w_PD', 'anat-PDT2w_T2');

-- Verify
-- SELECT mst.Scan_type, bss.BIDSScanTypeSubCategory, bst.BIDSScanType
-- FROM bids_mri_scan_type_rel bmstr
-- JOIN mri_scan_type mst ON bmstr.MRIScanTypeID = mst.ID
-- JOIN bids_scan_type bst ON bmstr.BIDSScanTypeID = bst.BIDSScanTypeID
-- LEFT JOIN bids_scan_type_subcategory bss ON bmstr.BIDSScanTypeSubCategoryID = bss.BIDSScanTypeSubCategoryID
-- WHERE mst.Scan_type IN ('anat-PDT2w_PD', 'anat-PDT2w_T2');
