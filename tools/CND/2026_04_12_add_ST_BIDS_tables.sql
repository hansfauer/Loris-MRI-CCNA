-- BIDS dimension + bids_mri_scan_type_rel rows for CCNA-style mri_scan_type names.
-- Run against your LORIS DB after confirming column names match (Loris versions vary slightly).
-- Prerequisites: bids_category must already contain anat, func, dwi, fmap (standard Loris imaging install).

-- ---------------------------------------------------------------------------
-- bids_scan_type (suffix in BIDS filename, before .nii.gz)
-- ---------------------------------------------------------------------------
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'PDw' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'PDw');
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'T2w' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'T2w');
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'FLAIR' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'FLAIR');
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'bold' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'bold');
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'dwi' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'dwi');
INSERT INTO bids_scan_type (BIDSScanType) SELECT 'epi' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type WHERE BIDSScanType = 'epi');

-- ---------------------------------------------------------------------------
-- bids_scan_type_subcategory (entities like task-rest, dir-AP; underscore joins multiple)
-- ---------------------------------------------------------------------------
INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'task-rest' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'task-rest');
INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'dir-AP' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'dir-AP');
INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'dir-PA' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'dir-PA');

INSERT INTO bids_scan_type_subcategory (BIDSScanTypeSubCategory)
SELECT 'acq-PDT2w' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory = 'acq-PDT2w');
-- ---------------------------------------------------------------------------
-- bids_mri_scan_type_rel
-- Use BIDSEchoNumber only where noted (JSON EchoNumber disambiguates via Python echo-aware BIDS lookup).
-- If your table has no BIDSEchoNumber column, drop that column from the INSERTs and use two mri_scan_types instead for PDT2w.
-- ---------------------------------------------------------------------------

-- anat-FLAIR
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID , BIDSCategoryID , BIDSScanTypeID, BIDSScanTypeSubCategoryID)
VALUES (
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-FLAIR'),
    (SELECT BIDSCategoryID FROM bids_category WHERE BIDSCategoryName='anat'),
    (SELECT BIDSScanTypeID FROM bids_scan_type WHERE BIDSScanType='FLAIR'),
    NULL
);


-- anat-T2w
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID , BIDSCategoryID , BIDSScanTypeID, BIDSScanTypeSubCategoryID)
VALUES (
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-T2w'),
    (SELECT BIDSCategoryID FROM bids_category WHERE BIDSCategoryName='anat'),
    (SELECT BIDSScanTypeID FROM bids_scan_type WHERE BIDSScanType='T2w'),
    NULL
);



-- anat-PDT2w: echo 1 -> PDw, echo 2 -> T2w (requires run_nifti_insertion echo-aware BIDS lookup)
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID , BIDSCategoryID , BIDSScanTypeID, BIDSScanTypeSubCategoryID)
VALUES (
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_PD'),
    (SELECT BIDSCategoryID FROM bids_category WHERE BIDSCategoryName='anat'),
    (SELECT BIDSScanTypeID FROM bids_scan_type WHERE BIDSScanType='PDw'),
    (SELECT BIDSScanTypeSubCategoryID FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory='acq-PDT2w')
);
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID , BIDSCategoryID , BIDSScanTypeID, BIDSScanTypeSubCategoryID)
VALUES (
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'anat-PDT2w_T2'),
    (SELECT BIDSCategoryID FROM bids_category WHERE BIDSCategoryName='anat'),
    (SELECT BIDSScanTypeID FROM bids_scan_type WHERE BIDSScanType='T2w'),
    (SELECT BIDSScanTypeSubCategoryID FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory='acq-PDT2w')
);
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT mst.ID, bc.BIDSCategoryID, bst.BIDSScanTypeID, NULL, 1
FROM mri_scan_type mst
CROSS JOIN bids_category bc
CROSS JOIN bids_scan_type bst
WHERE mst.Scan_type = 'anat-PDT2w'
  AND bc.BIDSCategoryName = 'anat'
  AND bst.BIDSScanType = 'PDw'
  AND NOT EXISTS (SELECT 1 FROM bids_mri_scan_type_rel r WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber = 1);

INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT mst.ID, bc.BIDSCategoryID, bst.BIDSScanTypeID, NULL, 2
FROM mri_scan_type mst
CROSS JOIN bids_category bc
CROSS JOIN bids_scan_type bst
WHERE mst.Scan_type = 'anat-PDT2w'
  AND bc.BIDSCategoryName = 'anat'
  AND bst.BIDSScanType = 'T2w'
  AND NOT EXISTS (SELECT 1 FROM bids_mri_scan_type_rel r WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber = 2);

-- func_task-rest -> func/bold + task-rest
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID , BIDSCategoryID , BIDSScanTypeID, BIDSScanTypeSubCategoryID)
VALUES (
    (SELECT ID FROM mri_scan_type WHERE Scan_type = 'func_task-rest'),
    (SELECT BIDSCategoryID FROM bids_category WHERE BIDSCategoryName='func'),
    (SELECT BIDSScanTypeID FROM bids_scan_type WHERE BIDSScanType='bold'),
    (SELECT BIDSScanTypeSubCategoryID FROM bids_scan_type_subcategory WHERE BIDSScanTypeSubCategory='task-rest')
);


-- dwi_dir-AP -> dwi/dwi + dir-AP
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT mst.ID, bc.BIDSCategoryID, bst.BIDSScanTypeID, bss.BIDSScanTypeSubCategoryID, NULL
FROM mri_scan_type mst
CROSS JOIN bids_category bc
CROSS JOIN bids_scan_type bst
CROSS JOIN bids_scan_type_subcategory bss
WHERE mst.Scan_type = 'dwi_dir-AP'
  AND bc.BIDSCategoryName = 'dwi'
  AND bst.BIDSScanType = 'dwi'
  AND bss.BIDSScanTypeSubCategory = 'dir-AP'
  AND NOT EXISTS (SELECT 1 FROM bids_mri_scan_type_rel r WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber IS NULL);

-- fmap-epi_dir-AP
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT mst.ID, bc.BIDSCategoryID, bst.BIDSScanTypeID, bss.BIDSScanTypeSubCategoryID, NULL
FROM mri_scan_type mst
CROSS JOIN bids_category bc
CROSS JOIN bids_scan_type bst
CROSS JOIN bids_scan_type_subcategory bss
WHERE mst.Scan_type = 'fmap-epi_dir-AP'
  AND bc.BIDSCategoryName = 'fmap'
  AND bst.BIDSScanType = 'epi'
  AND bss.BIDSScanTypeSubCategory = 'dir-AP'
  AND NOT EXISTS (SELECT 1 FROM bids_mri_scan_type_rel r WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber IS NULL);

-- fmap-epi_dir-PA
INSERT INTO bids_mri_scan_type_rel (MRIScanTypeID, BIDSCategoryID, BIDSScanTypeID, BIDSScanTypeSubCategoryID, BIDSEchoNumber)
SELECT mst.ID, bc.BIDSCategoryID, bst.BIDSScanTypeID, bss.BIDSScanTypeSubCategoryID, NULL
FROM mri_scan_type mst
CROSS JOIN bids_category bc
CROSS JOIN bids_scan_type bst
CROSS JOIN bids_scan_type_subcategory bss
WHERE mst.Scan_type = 'fmap-epi_dir-PA'
  AND bc.BIDSCategoryName = 'fmap'
  AND bst.BIDSScanType = 'epi'
  AND bss.BIDSScanTypeSubCategory = 'dir-PA'
  AND NOT EXISTS (SELECT 1 FROM bids_mri_scan_type_rel r WHERE r.MRIScanTypeID = mst.ID AND r.BIDSEchoNumber IS NULL);
