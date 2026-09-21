# Open Science DICOM de-identification policy changes

## 2026-09-17

Reconciled `fields_to_zap_for_open_science.xml` with the approved keep/remove/modify policy and the read-only review of `DCM_2019-07-03_ImagingUpload-14-46-PCv8DD`.

Removed from the zap list because they must be kept:

- `0010,0040` PatientSex
- `0010,1010` PatientAge
- `0008,0080` InstitutionName
- `0008,0081` InstitutionAddress
- `0008,0082` InstitutionCodeSequence
- `0008,1040` InstitutionalDepartmentName
- `0008,1010` StationName
- `0008,0030` StudyTime
- `0008,0031` SeriesTime
- `0008,0032` AcquisitionTime
- `0008,0033` ContentTime
- `0020,000E` SeriesInstanceUID
- `0020,000D` StudyInstanceUID

Changed to `editable=yes` because they must be modified, not removed:

- `0010,0020` PatientID
- `0008,0020` StudyDate
- `0008,0021` SeriesDate
- `0008,0022` AcquisitionDate
- `0008,0023` ContentDate
- `0008,0012` InstanceCreationDate
- `0008,002A` AcquisitionDateTime
- `0040,0244` PerformedProcedureStepStartDate
- `0040,0250` PerformedProcedureStepEndDate

The original instruction to modify `0020,000D` StudyInstanceUID was a typo. It
is intentionally absent from the zap XML and remains unchanged.

Corrected the Occupation tag from the duplicate, incorrect `0010,2160` to `0010,2180`. Removed a duplicate use of `0008,0012` that was incorrectly labelled `StudiesContainingOtherReferencedInstancesSequence`.

Added the missing removal entries `0002,0012` ImplementationClassUID, `0002,0013` ImplementationVersionName, `0008,0050` AccessionNumber, `0008,1050` PerformingPhysicianName, and `0040,0280` CommentsOnPerformedProcedureStep.

The GE archive review found `0018,1030` ProtocolName values `18-6189_CDIP_CCNA_25JUN/` and `18-6189_CDIP_CCNA_25JUN2`; it has been added as a removal candidate because both contain the study identifier and a date-like component.