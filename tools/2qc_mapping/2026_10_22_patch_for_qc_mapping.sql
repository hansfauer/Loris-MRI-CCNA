/* run this in the terminal mysql -A:
source /opt/ccnaopen/bin/mri/tools/qc_mapping/feedback_mri_comment_types.sql
source /opt/ccnaopen/bin/mri/tools/qc_mapping/feedback_mri_comments_DicomArchiveID_SeriesNumber_EchoTime.sql
source /opt/ccnaopen/bin/mri/tools/qc_mapping/feedback_mri_predefined_comments.sql
source /opt/ccnaopen/bin/mri/tools/qc_mapping/files_qcstatus_DicomArchiveID_SeriesNumber_EchoTime.sql
*/

-- Create a table with the old FileID and the DicomArchiveID (a.k.a. StudyUID)
CREATE TEMPORARY TABLE map_fileID_DicomArchiveID AS 
  SELECT f.FileID, DicomArchiveID 
  FROM files f 
    JOIN tarchive t ON (t.TarchiveID=f.TarchiveSource)
    WHERE f.OutputType = 'defaced';
-- Create another temporary table with all the fields from FileID and the SeriesNumber from parameter_file
CREATE TEMPORARY TABLE map_fileID_SeriesNumber AS
  SELECT FileID, Value AS SeriesNumber 
  FROM parameter_file 
    JOIN parameter_type USING (ParameterTypeID)  
  WHERE Name="series_number";
-- Create another temporary table with all the fields from FileID and the EchoTime from parameter_file
CREATE TEMPORARY TABLE map_fileID_EchoTime AS
  SELECT FileID, Value AS EchoTime 
  FROM parameter_file 
    JOIN parameter_type USING (ParameterTypeID)  
  WHERE Name="echo_time";

-- Create the final table with all the fields from map_fileID_SeriesNumber and map_fileID_DicomArchiveID_EchoTime into one single table that can be used later on to map QC and feedback information.
CREATE TEMPORARY TABLE map_fileID_DicomArchiveID_SeriesNumber_EchoTime AS 
  SELECT mfs.FileID, DicomArchiveID, SeriesNumber, EchoTime 
  FROM map_fileID_DicomArchiveID 
    JOIN map_fileID_SeriesNumber mfs USING (FileID)
    JOIN map_fileID_EchoTime USING (FileID); 

-- 6) Insert the QC status and MRI Comments from the original database into the open VM with the proper FileIDs
--- 1.Insert into files_qcstatus table the QC status
CREATE TEMPORARY TABLE FileIDs AS
  SELECT FileQCID, mdse.FileID, QCStatus, QCFirstChangeTime, QCLastChangeTime, Selected, DicomArchiveID, SeriesNumber, EchoTime
  FROM files_qcstatus_DicomArchiveID_SeriesNumber_EchoTime fqdse
    JOIN map_fileID_DicomArchiveID_SeriesNumber_EchoTime mdse USING (DicomArchiveID, SeriesNumber, EchoTime);

-- delete the extra rows in FileIDs that have multiple matching source QC row. this was from old bug. manually inspected what to remove
-- fileIDs fileID rows to delete: 4861, 4862  T2* phase
-- fileIDs fileID to delete: 5625, 5626  T2* phase
-- fileIDs fileID to delete: 7589, 7590  T2* phase
-- fileIDs fileID to delete: 7272,7273 T2* phase
-- fileIDs fileID to delete: 5954  T2 FLAIR duplicate

DELETE FROM FileIDs
WHERE (FileQCID, FileID) IN (
  (5795, 9655),
  (5473, 10615),
  (5474, 10615),
  (7074, 14818),
  (7075, 14818),
  (4733, 12379),
  (4734, 12379),
  (7313, 14531),
  (7314, 14531)
);

SELECT ROW_COUNT() AS deleted_rows;

-- then insert the perfect 1 to 1 mapping of QC
INSERT INTO files_qcstatus (FileQCID, FileID, QCStatus, QCFirstChangeTime, QCLastChangeTime, Selected) 
  SELECT FileQCID, FileID, QCStatus, QCFirstChangeTime, QCLastChangeTime, Selected FROM FileIDs;


--- 2. insert into feedback_mri_comments table the MRI comments
CREATE TEMPORARY TABLE FeedbackIDs AS
  SELECT CommentID, mdse.FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime, DicomArchiveID, SeriesNumber, EchoTime
  FROM feedback_mri_comments_DicomArchiveID_SeriesNumber_EchoTime fmcdse
    JOIN map_fileID_DicomArchiveID_SeriesNumber_EchoTime mdse USING (DicomArchiveID, SeriesNumber, EchoTime);
-- remove comments from removed QC scans in internal db
DELETE FROM FeedbackIDs
WHERE FileID IN (9655, 10615, 14818, 12379, 14531);

SELECT ROW_COUNT() AS deleted_rows;

-- then insert in the mri comments table
INSERT INTO feedback_mri_comments (CommentID, FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime)
  SELECT CommentID, FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime FROM FeedbackIDs;


-- remove date information from the feedback_mri_comments table
 UPDATE feedback_mri_comments SET ChangeTime=CURRENT_TIMESTAMP;

-- remove date information from the files_qcstatus table
 UPDATE files_qcstatus SET QCFirstChangeTime=NULL;
 UPDATE files_qcstatus SET QCLastChangeTime=NULL;





SELECT f.OutputType, COUNT(*) AS mapped_rows
FROM FileIDs mapped
JOIN files f ON f.FileID = mapped.FileID
GROUP BY f.OutputType;
SELECT FileQCID,
       COUNT(*) AS matching_rows,
       COUNT(DISTINCT FileID) AS matching_files
FROM FileIDs
GROUP BY FileQCID
HAVING COUNT(*) > 1;
SHOW CREATE TABLE files_qcstatus;
select * from files_qcstatus;
desc files_qcstatus;
SELECT *
FROM files_qcstatus
WHERE FileQCID = 3305;

SELECT *
FROM FileIDs
WHERE FileQCID = 3305;
-- Insert into feedback_mri_comments table the MRI comments
CREATE TEMPORARY TABLE FeedbackIDs AS
  SELECT CommentID, mdse.FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime, DicomArchiveID, SeriesNumber, EchoTime
  FROM feedback_mri_comments_DicomArchiveID_SeriesNumber_EchoTime fmcdse
    JOIN map_fileID_DicomArchiveID_SeriesNumber_EchoTime mdse USING (DicomArchiveID, SeriesNumber, EchoTime);

INSERT INTO feedback_mri_comments (CommentID, FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime)
  SELECT CommentID, FileID, SessionID, CommentTypeID, PredefinedCommentID, Comment, ChangeTime FROM FeedbackIDs;
-- remove date information from the feedback_mri_comments table
 UPDATE feedback_mri_comments SET ChangeTime=CURRENT_TIMESTAMP;
-- remove date information from the files_qcstatus table
 UPDATE files_qcstatus SET QCFirstChangeTime=NULL;
 UPDATE files_qcstatus SET QCLastChangeTime=NULL;