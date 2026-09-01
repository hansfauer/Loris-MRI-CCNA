#!/usr/bin/perl

=pod

=head1 NAME

copy_tarchives_from_pscid_list.pl - untar DICOM tarchives for PSCIDs listed in a CSV

=head1 SYNOPSIS

perl copy_tarchives_from_pscid_list.pl -profile prod /path/to/output_folder
    [-csv /path/to/pscid_list.csv] [-sourceroot name] [-dryrun]

Required argument:

outdir   : output folder where selected DICOM archives are extracted
           (each archive goes into C<< <outdir>/<tarchive_basename>/ >>)

Available options are:

-profile    : name of the config file in C<$LORIS_CONFIG/.loris_mri> (typically C<prod>)

-csv        : CSV with a PSCID column (defaults to Initial_Release_List_REGISTERED.csv
              next to this script)

-sourceroot : replace the first directory in each resolved tarchive path with this
              name. Example: with C<-sourceroot ccna-prod-data>,
              C</data/ccna/data/tarchive/2019/DCM_....tar> becomes
              C</ccna-prod-data/ccna/data/tarchive/2019/DCM_....tar>

-dryrun     : report what would be extracted without running tar

=head1 DESCRIPTION

Reads PSCIDs from a CSV, looks up matching DICOM archives in the database via:

    SELECT c.PSCID, t.PatientName, t.ArchiveLocation, t.DateAcquired, s.Visit_label
    FROM tarchive t
    JOIN session s ON (s.ID = t.SessionID)
    JOIN candidate c ON (c.CandID = s.CandID)
    WHERE c.PSCID IN (...)
      AND t.PatientName LIKE '%Initial_MRI%'

Only sessions whose patient name contains C<Initial_MRI> are processed.

Resolves relative C<ArchiveLocation> values against the C<tarchiveLibraryDir>
config setting. If C<-sourceroot> is set, the first directory component of each
resolved path is replaced before extraction.

Each selected archive is extracted into the output folder with a two-step untar
(same idea as C<batch_untar.pl>, run twice, without qsub):

1. C<tar -C E<lt>extract_dirE<gt> -xf E<lt>outer.tarE<gt>>
2. find the single inner C<.tar.gz>, then
   C<tar -C E<lt>extract_dirE<gt> -xzf E<lt>inner.tar.gzE<gt>>

Writes a summary log to C<< <outdir>/untar_tarchives_summary.tsv >>.

=cut

use strict;
use warnings;

use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use Getopt::Tabular;

use NeuroDB::DBI;
use NeuroDB::ExitCodes;

use NeuroDB::Database;
use NeuroDB::DatabaseException;

use NeuroDB::objectBroker::ObjectBrokerException;
use NeuroDB::objectBroker::ConfigOB;

my $DEFAULT_CSV = File::Spec->catfile(
    dirname(__FILE__),
    'Initial_Release_List_REGISTERED.csv'
);

my $profile;
my $csv_path = $DEFAULT_CSV;
my $sourceroot;
my $dryrun;

my $profile_desc    = "name of config file in \$LORIS_CONFIG/.loris_mri";
my $csv_desc        = "CSV file containing a PSCID column";
my $sourceroot_desc = "replace the first directory in each tarchive path with this name";
my $dryrun_desc     = "print actions without extracting archives";

my @opt_table = (
    [ "-profile",    "string",  1, \$profile,    $profile_desc ],
    [ "-csv",        "string",  1, \$csv_path,   $csv_desc ],
    [ "-sourceroot", "string",  1, \$sourceroot, $sourceroot_desc ],
    [ "-dryrun",     "boolean", 0, \$dryrun,     $dryrun_desc ],
);

my $Help = <<HELP;
****************************************************
Untar DICOM tarchives for PSCIDs listed in a CSV
****************************************************

Looks up ArchiveLocation for each PSCID via tarchive/session/candidate,
keeps only PatientName values containing Initial_MRI, then double-untars
each archive into the output folder (outer .tar, then inner .tar.gz),
without qsub.

Documentation: perldoc $0

HELP

my $Usage = <<USAGE;
usage: $0 -profile <profile> <outdir> [-csv <file>] [-sourceroot <name>] [-dryrun]
       $0 -help to list options
USAGE

&Getopt::Tabular::SetHelp( $Help, $Usage );
&Getopt::Tabular::GetOptions( \@opt_table, \@ARGV )
    || exit $NeuroDB::ExitCodes::GETOPT_FAILURE;

my $outdir = shift @ARGV;
if ( !$profile ) {
    print $Help;
    print STDERR "$Usage\n\tERROR: missing -profile argument\n\n";
    exit $NeuroDB::ExitCodes::PROFILE_FAILURE;
}
if ( !defined $outdir || $outdir eq '' ) {
    print STDERR "$Usage\n\tERROR: missing output folder argument\n\n";
    exit $NeuroDB::ExitCodes::MISSING_ARG;
}
if (@ARGV) {
    print STDERR "$Usage\n\tERROR: unexpected argument(s): @ARGV\n\n";
    exit $NeuroDB::ExitCodes::INVALID_ARG;
}
if ( defined $sourceroot ) {
    $sourceroot =~ s{^/+|/+$}{}g;
    if ( $sourceroot eq '' || $sourceroot =~ m{/} ) {
        print STDERR "ERROR: -sourceroot must be a single directory name "
            . "(e.g. ccna-prod-data), got: $sourceroot\n";
        exit $NeuroDB::ExitCodes::INVALID_ARG;
    }
}
if ( !-f $csv_path ) {
    print STDERR "ERROR: CSV file not found: $csv_path\n";
    exit $NeuroDB::ExitCodes::INVALID_ARG;
}

{ package Settings; do "$ENV{LORIS_CONFIG}/.loris_mri/$profile" }
if ( !@Settings::db ) {
    print STDERR "\n\tERROR: You don't have a \@db setting in the file "
        . "$ENV{LORIS_CONFIG}/.loris_mri/$profile \n\n";
    exit $NeuroDB::ExitCodes::DB_SETTINGS_FAILURE;
}

# ----------------------------------------------------------------
## Establish database connection
# ----------------------------------------------------------------
my $dbh = &NeuroDB::DBI::connect_to_db(@Settings::db);

my $db = NeuroDB::Database->new(
    databaseName => $Settings::db[0],
    userName     => $Settings::db[1],
    password     => $Settings::db[2],
    hostName     => $Settings::db[3]
);
$db->connect();

my $configOB = NeuroDB::objectBroker::ConfigOB->new( db => $db );
my $tarchiveLibraryDir = $configOB->getTarchiveLibraryDir();
$tarchiveLibraryDir =~ s#/$## if defined $tarchiveLibraryDir;
if ( defined $sourceroot ) {
    print "Replacing first path directory with: /$sourceroot\n";
}

# ----------------------------------------------------------------
## Read PSCIDs from CSV
# ----------------------------------------------------------------
my @pscids = read_pscids_from_csv($csv_path);
if ( !@pscids ) {
    print STDERR "ERROR: no PSCIDs found in $csv_path\n";
    exit $NeuroDB::ExitCodes::INVALID_ARG;
}
print "Loaded " . scalar(@pscids) . " unique PSCIDs from $csv_path\n";

# ----------------------------------------------------------------
## Query tarchives for those PSCIDs
# ----------------------------------------------------------------
my $placeholders = join( ',', map { '?' } @pscids );
my $query = <<"SQL";
SELECT c.PSCID, t.PatientName, t.ArchiveLocation, t.DateAcquired, s.Visit_label
FROM tarchive t
JOIN session s ON (s.ID = t.SessionID)
JOIN candidate c ON (c.CandID = s.CandID)
WHERE c.PSCID IN ($placeholders)
  AND t.PatientName LIKE '%Initial_MRI%'
ORDER BY c.PSCID, t.DateAcquired, t.ArchiveLocation
SQL

my $sth = $dbh->prepare($query);
$sth->execute(@pscids);

my %found_pscids;
my @rows;
while ( my $row = $sth->fetchrow_hashref() ) {
    push @rows, $row;
    $found_pscids{ $row->{PSCID} } = 1;
}

print "Found " . scalar(@rows) . " Initial_MRI tarchive row(s) for "
    . scalar(keys %found_pscids) . " PSCID(s)\n";

my @missing_pscids = grep { !$found_pscids{$_} } @pscids;
if (@missing_pscids) {
    print "WARNING: " . scalar(@missing_pscids)
        . " PSCID(s) had no Initial_MRI tarchive (PatientName LIKE '%Initial_MRI%'):\n";
    print "  $_\n" for @missing_pscids;
}

# ----------------------------------------------------------------
## Double-untar archives into outdir
# ----------------------------------------------------------------
if ( !$dryrun ) {
    make_path($outdir) unless -d $outdir;
}

my $summary_path = File::Spec->catfile( $outdir, 'untar_tarchives_summary.tsv' );
open my $summary_fh, '>', $summary_path
    or die "Cannot write summary $summary_path: $!\n"
    unless $dryrun;

if ( !$dryrun ) {
    print {$summary_fh} join(
        "\t",
        qw(PSCID Visit_label PatientName DateAcquired ArchiveLocation FullPath ExtractDir InnerTar Status)
    ), "\n";
}

my ( $extracted, $skipped_missing_file, $skipped_exists, $errors ) = ( 0, 0, 0, 0 );

foreach my $row (@rows) {
    my $pscid            = $row->{PSCID}            // '';
    my $visit_label      = $row->{Visit_label}      // '';
    my $patient_name     = $row->{PatientName}      // '';
    my $date_acquired    = $row->{DateAcquired}     // '';
    my $archive_location = $row->{ArchiveLocation}  // '';

    my $full_path = resolve_archive_path( $archive_location, $tarchiveLibraryDir );
    $full_path = replace_first_directory( $full_path, $sourceroot )
        if defined $full_path && defined $sourceroot;

    my $basename    = defined $full_path ? basename($full_path) : '';
    my $extract_stem = $basename;
    $extract_stem =~ s/\.tar(\.gz)?$//i;
    my $extract_dir = File::Spec->catdir( $outdir, $extract_stem );

    my $status;
    my $inner_tar = '';

    if ( !defined $full_path || $full_path eq '' ) {
        $status = 'ERROR_EMPTY_ARCHIVE_LOCATION';
        $errors++;
        warn "ERROR: empty ArchiveLocation for PSCID=$pscid PatientName=$patient_name\n";
    }
    elsif ( !-f $full_path ) {
        $status = 'ERROR_SOURCE_MISSING';
        $skipped_missing_file++;
        warn "ERROR: source file missing: $full_path (PSCID=$pscid)\n";
    }
    elsif ( $dryrun ) {
        $status = 'DRYRUN_WOULD_UNTAR';
        print "[dryrun] outer: tar -C $extract_dir -xf $full_path\n";
        print "[dryrun] inner: tar -C $extract_dir -xzf <single .tar.gz found in $extract_dir>\n";
        $extracted++;
    }
    elsif ( -d $extract_dir && !is_dir_empty($extract_dir) ) {
        $status = 'SKIPPED_DEST_EXISTS';
        $skipped_exists++;
        print "SKIP (exists): $extract_dir\n";
    }
    else {
        my ( $ok, $detail ) = extract_tarchive_twice( $full_path, $extract_dir );
        if ($ok) {
            $status    = 'EXTRACTED';
            $inner_tar = $detail;
            $extracted++;
            print "EXTRACTED: $full_path -> $extract_dir (inner=$inner_tar)\n";
        }
        else {
            $status = "ERROR_UNTAR: $detail";
            $errors++;
            warn "ERROR: failed to untar $full_path into $extract_dir: $detail\n";
        }
    }

    if ( !$dryrun ) {
        print {$summary_fh} join(
            "\t",
            $pscid,
            $visit_label,
            $patient_name,
            $date_acquired,
            $archive_location,
            $full_path // '',
            $extract_dir,
            $inner_tar,
            $status
        ), "\n";
    }
}

# Also record PSCIDs with no DB rows in the summary
if ( !$dryrun ) {
    foreach my $pscid (@missing_pscids) {
        print {$summary_fh} join(
            "\t",
            $pscid, '', '', '', '', '', '', '', 'NO_TARCHIVE_IN_DB'
        ), "\n";
    }
    close $summary_fh;
}

print "\n=== Summary ===\n";
print "PSCIDs requested          : " . scalar(@pscids) . "\n";
print "PSCIDs with tarchives     : " . scalar(keys %found_pscids) . "\n";
print "PSCIDs missing tarchives  : " . scalar(@missing_pscids) . "\n";
print "Tarchive rows             : " . scalar(@rows) . "\n";
print( $dryrun ? "Would extract            : $extracted\n" : "Extracted                : $extracted\n" );
print "Source file missing       : $skipped_missing_file\n";
print "Skipped (dest exists)     : $skipped_exists\n";
print "Errors                    : $errors\n";
print "Summary TSV               : $summary_path\n" unless $dryrun;

$dbh->disconnect();
$db->disconnect();
exit 0;


=pod

=head3 read_pscids_from_csv($path)

Reads unique non-empty PSCID values from a CSV. Uses the C<PSCID> header column
when present; otherwise uses the first column.

=cut

sub read_pscids_from_csv {
    my ($path) = @_;

    open my $fh, '<', $path or die "Cannot open CSV $path: $!\n";

    my $header_line = <$fh>;
    die "ERROR: empty CSV: $path\n" unless defined $header_line;
    $header_line =~ s/\r?\n$//;

    my @headers = split_csv_line($header_line);
    my $pscid_idx;
    for ( my $i = 0; $i < @headers; $i++ ) {
        if ( lc( $headers[$i] ) eq 'pscid' ) {
            $pscid_idx = $i;
            last;
        }
    }
    $pscid_idx = 0 unless defined $pscid_idx;

    my %seen;
    my @pscids;
    while ( my $line = <$fh> ) {
        $line =~ s/\r?\n$//;
        next if $line !~ /\S/;

        my @fields = split_csv_line($line);
        my $pscid  = $fields[$pscid_idx] // '';
        $pscid =~ s/^\s+|\s+$//g;
        next if $pscid eq '' || lc($pscid) eq 'pscid';

        next if $seen{$pscid}++;
        push @pscids, $pscid;
    }
    close $fh;

    return @pscids;
}


=pod

=head3 split_csv_line($line)

Minimal CSV splitter for simple comma-separated rows (no embedded commas expected
in PSCID lists).

=cut

sub split_csv_line {
    my ($line) = @_;
    my @fields = split /,/, $line, -1;
    for (@fields) {
        s/^\s+|\s+$//g;
        s/^"(.*)"$/$1/;
    }
    return @fields;
}


=pod

=head3 resolve_archive_path($archive_location, $tarchive_library_dir)

Returns an absolute filesystem path for a tarchive C<ArchiveLocation>. Relative
paths are prefixed with C<tarchiveLibraryDir>.

=cut

sub resolve_archive_path {
    my ( $archive_location, $tarchive_library_dir ) = @_;

    return undef unless defined $archive_location && $archive_location ne '';

    return $archive_location if $archive_location =~ m{^/};

    die "ERROR: ArchiveLocation '$archive_location' is relative but "
        . "tarchiveLibraryDir is not configured\n"
        unless defined $tarchive_library_dir && $tarchive_library_dir ne '';

    return "$tarchive_library_dir/$archive_location";
}


=pod

=head3 replace_first_directory($path, $new_root)

Replaces the first directory component of an absolute path. For example, with
C<$new_root = 'ccna-prod-data'>:

C</data/ccna/data/tarchive/2019/file.tar>
becomes
C</ccna-prod-data/ccna/data/tarchive/2019/file.tar>

=cut

sub replace_first_directory {
    my ( $path, $new_root ) = @_;

    return $path unless defined $path && defined $new_root && $new_root ne '';

    if ( $path =~ m{^/([^/]+)(/.*)?$} ) {
        my $rest = $2 // '';
        return "/$new_root$rest";
    }

    if ( $path =~ m{^([^/]+)(/.*)?$} ) {
        my $rest = $2 // '';
        return "$new_root$rest";
    }

    return $path;
}


=pod

=head3 is_dir_empty($dir)

Returns true if C<$dir> exists and contains no entries other than C<.> / C<..>.

=cut

sub is_dir_empty {
    my ($dir) = @_;

    opendir my $dh, $dir or return 0;
    while ( my $entry = readdir($dh) ) {
        next if $entry eq '.' || $entry eq '..';
        closedir $dh;
        return 0;
    }
    closedir $dh;
    return 1;
}


=pod

=head3 extract_tarchive_twice($tarchive, $extract_dir)

Extracts a LORIS DICOM archive in two steps into C<$extract_dir>:

1. Untar the outer C<.tar> (or C<.tar.gz>/C<.tgz>)
2. Find the single inner C<.tar.gz> and untar it

Returns C<(1, $inner_tar_basename)> on success, or C<(0, $error_message)> on failure.
Does not use qsub; runs C<tar> locally.

=cut

sub extract_tarchive_twice {
    my ( $tarchive, $extract_dir ) = @_;

    make_path($extract_dir) unless -d $extract_dir;

    my $outer_opts = '-xf';
    $outer_opts = '-xzf' if $tarchive =~ m/\.gz|\.tgz/i;

    my $cmd1 = sprintf(
        'tar -C %s %s %s',
        quotemeta($extract_dir),
        $outer_opts,
        quotemeta($tarchive)
    );
    print "  $cmd1\n";
    if ( system($cmd1) != 0 ) {
        return ( 0, "outer untar failed (exit=$?): $cmd1" );
    }

    opendir my $dh, $extract_dir
        or return ( 0, "cannot read $extract_dir: $!" );
    my @tars = grep { /\.tar\.gz$/i && -f File::Spec->catfile( $extract_dir, $_ ) }
        readdir($dh);
    closedir $dh;

    if ( @tars != 1 ) {
        return (
            0,
            "expected exactly 1 inner .tar.gz in $extract_dir, found "
                . scalar(@tars)
                . ( @tars ? (' [' . join( ', ', @tars ) . ']') : '' )
        );
    }

    my $inner_tar  = $tars[0];
    my $inner_path = File::Spec->catfile( $extract_dir, $inner_tar );

    my $cmd2 = sprintf(
        'tar -C %s -xzf %s',
        quotemeta($extract_dir),
        quotemeta($inner_path)
    );
    print "  $cmd2\n";
    if ( system($cmd2) != 0 ) {
        return ( 0, "inner untar failed (exit=$?): $cmd2" );
    }

    return ( 1, $inner_tar );
}
