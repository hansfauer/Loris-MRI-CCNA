-- Phase 1/2 scan type renames (CCNA-style naming).
-- Preserves mri_scan_type.ID; mri_protocol / files / bids_mri_scan_type_rel FKs stay valid.

-- T1w Scans: converge mri_protocol rows from 3d_t1w to anat-T1w
UPDATE mri_protocol AS mp
JOIN mri_scan_type AS src ON mp.Scan_type = src.ID AND src.Scan_type = '3d_t1w'
JOIN mri_scan_type AS dst ON dst.Scan_type = 'anat-T1w'
SET mp.Scan_type = dst.ID;

-- PDT2w Scans: change scan type names from dual_pd to anat-PDT2-PDw and dual-t2 to anat-PDT2-T2w
UPDATE mri_scan_type
SET Scan_type = 'anat-PDT2-PDw'
WHERE Scan_type = 'dual_pd'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-PDT2-PDw');

UPDATE mri_scan_type
SET Scan_type = 'anat-PDT2-T2w'
WHERE Scan_type = 'dual-t2'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-PDT2-T2w');

-- FLAIR scans: change scan type names from 2d_flair to anat-FLAIR-2D and anat-flair to anat-FLAIR-3D
UPDATE mri_scan_type
SET Scan_type = 'anat-FLAIR-2D'
WHERE Scan_type = '2d_flair'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-FLAIR-2D');

UPDATE mri_scan_type
SET Scan_type = 'anat-FLAIR-3D'
WHERE Scan_type = 'anat-FLAIR'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-FLAIR-3D');

-- T2* scans: split scan type names from t2_star to anat-T2starw-Phase and anat-T2starw-Mag
UPDATE mri_scan_type
SET Scan_type = 'anat-T2starw-Phase'
WHERE Scan_type = 't2_star'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'anat-T2starw-Phase');

INSERT INTO mri_scan_type (Scan_type) Values 
('anat-T2starw-Mag');

-- SWI scans: change scan type names from swi to swi-mag, swi-pha,swi-SWI, swi-minIP
UPDATE mri_scan_type
SET Scan_type = 'swi-mag'
WHERE Scan_type = 'swi'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'swi-mag');

insert into mri_scan_type (Scan_type) Values 
('swi-pha'),
('swi-SWI'),
('swi-minIP');

-- BOLD scans: change scan type names from bold to func-bold
UPDATE mri_scan_type
SET Scan_type = 'swi-mag'
WHERE Scan_type = 'func_task-rest'
  AND NOT EXISTS (SELECT 1 FROM mri_scan_type WHERE Scan_type = 'swi-mag');






-- SDs to exclude from the scan type T1w renames:
INSERT INTO Config (ConfigID, Value)
VALUES
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'svs_se_135_Motor R'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'svs_se_135_post _cing'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'svs_se_135_Motor R_unsup'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'svs_se_135_post _cing_unsup'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'VOI_Motor_R'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'VOI_Motor R'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'VOI_L_hip'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'VOI_MotorR'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'VOI_post_cing'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'mpr cor'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), '<MPR Collection>'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'ax reformat'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'ax reformat do not send'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'AX'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'Cor'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'MultiPlanar Reconstruction (MPR) Ob_Cor_P -> A_Average'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'MultiPlanar Reconstruction (MPR) Ob_Ax_I -> S_Average');

-- SDs to exclude for resting state:
INSERT INTO Config (ConfigID, Value)
VALUES
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'TASK-fMRI'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'Aud. Languag: A - X'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'MoCoSeries'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'Mean Epi (250)'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'Resting State(ep2d_bold_moco)');

-- SDs to exclude for T2* renames:
INSERT INTO Config (ConfigID, Value)
VALUES
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'T2-star_PM'),
    ((SELECT ID FROM ConfigSettings WHERE Name='excluded_series_description'), 'T2-star_PMRI');