#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Event Filter Script, $Date: 2011-08-26 10:05:42 +0100 (Fri, 26 Aug 2011) $, $Revision: 3506 $
# Copyright (C) 2001-2008 Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
# ==========================================================================
#
# This script continuously monitors the recorded events for the given
# monitor and applies any filters which would delete and/or upload 
# matching events
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant START_DELAY => 5; # How long to wait before starting

# ==========================================================================
#
# You shouldn't need to change anything from here downwards
#
# ==========================================================================

# Include from system perl paths only
use ZoneMinder;
use DBI;
use POSIX;
use Time::HiRes qw/gettimeofday/;
use Date::Manip;
use Getopt::Long;
use Data::Dumper;

use constant EVENT_PATH => (ZM_DIR_EVENTS=~m|/|)?ZM_DIR_EVENTS:(ZM_PATH_WEB.'/'.ZM_DIR_EVENTS);

logInit();
logSetSignal();

if ( ZM_OPT_UPLOAD )
{
    # Comment these out if you don't have them and don't want to upload
    # or don't want to use that format
    if ( ZM_UPLOAD_ARCH_FORMAT eq "zip" )
    {
        require Archive::Zip;
        import Archive::Zip qw( :ERROR_CODES :CONSTANTS );
    }
    else
    {
        require Archive::Tar;
    }
    if ( ZM_UPLOAD_PROTOCOL eq "ftp" )
    {
        require Net::FTP;
    }
    else
    {
        require Net::SFTP::Foreign;
    }
}

if ( ZM_OPT_EMAIL )
{
    if ( ZM_NEW_MAIL_MODULES )
    {
        require MIME::Lite;
        require Net::SMTP;
    }
    else
    {
        require MIME::Entity;
    }
}

if ( ZM_OPT_MESSAGE )
{
    if ( ZM_NEW_MAIL_MODULES )
    {
        require MIME::Lite;
        require Net::SMTP;
    }
    else
    {
        require MIME::Entity;
    }
}


$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $delay = ZM_FILTER_EXECUTE_INTERVAL;
my $event_id = 0;
my $filter_parm = "";

sub Usage
{
    print( "
Usage: zmfilter.pl [-f <filter name>,--filter=<filter name>]
Parameters are :-
-f<filter name>, --filter=<filter name>  - The name of a specific filter to run
");
    exit( -1 );
}

#
# More or less replicates the equivalent PHP function
#
sub strtotime
{
    my $dt_str = shift;
    return( UnixDate( $dt_str, '%s' ) );
}

#
# More or less replicates the equivalent PHP function
#
sub str_repeat
{
    my $string = shift;
    my $count = shift;
    return( ${string}x${count} );
}

# Formats a date into MySQL format
sub DateTimeToSQL
{
    my $dt_str = shift;
    my $dt_val = strtotime( $dt_str );
    if ( !$dt_val )
    {
        Error( "Unable to parse date string '$dt_str'\n" );
        return( undef );
    }
    return( strftime( "%Y-%m-%d %H:%M:%S", localtime( $dt_val ) ) );
}

if ( !GetOptions( 'filter=s'=>\$filter_parm ) )
{
    Usage();
}

chdir( EVENT_PATH );

my $dbh = zmDbConnect();

if ( $filter_parm )
{
    Info( "Scanning for events using filter '$filter_parm'\n" );
}
else
{
    Info( "Scanning for events\n" );
}

if ( !$filter_parm )
{
    sleep( START_DELAY );
}

my $filters;
my $last_action = 0;

while( 1 )
{
    if ( (time() - $last_action) > ZM_FILTER_RELOAD_DELAY )
    {
        Debug( "Reloading filters\n" );
        $last_action = time();
        $filters = getFilters( $filter_parm );
    }

    foreach my $filter ( @$filters )
    {
        checkFilter( $filter );
    }

    last if ( $filter_parm );

    Debug( "Sleeping for $delay seconds\n" );
    sleep( $delay );
}

sub getDiskPercent
{
    my $command = "df .";
    my $df = qx( $command );
    my $space = -1;
    if ( $df =~ /\s(\d+)%/ms )
    {
        $space = $1;
    }
    return( $space );
}

sub getDiskBlocks
{
    my $command = "df .";
    my $df = qx( $command );
    my $space = -1;
    if ( $df =~ /\s(\d+)\s+\d+\s+\d+%/ms )
    {
        $space = $1;
    }
    return( $space );
}

sub getLoad
{
    my $command = "uptime .";
    my $uptime = qx( $command );
    my $load = -1;
    if ( $uptime =~ /load average:\s+([\d.]+)/ms )
    {
        $load = $1;
        Info( "Load: $load" );
    }
    return( $load );
}

sub getFilters
{
    my $filter_name = shift;

    my @filters;
    my $sql = "select * from Filters where";
    if ( $filter_name )
    {
        $sql .= " Name = ? and";
    }
    else
    {
        $sql .= " Background = 1 and";
    }
    $sql .= " (AutoArchive = 1 or AutoVideo = 1 or AutoUpload = 1 or AutoEmail = 1 or AutoMessage = 1 or AutoExecute = 1 or AutoDelete = 1) order by Name";
    my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res;
    if ( $filter_name )
    {
        $res = $sth->execute( $filter_name ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
    }
    else
    {
        $res = $sth->execute() or Fatal( "Can't execute '$sql': ".$sth->errstr() );
    }
    FILTER: while( my $db_filter = $sth->fetchrow_hashref() )
    {
        Debug( "Found filter '$db_filter->{Name}'\n" );
        my $filter_expr = jsonDecode( $db_filter->{Query} );
        my $sql = "select E.Id,E.MonitorId,M.Name as MonitorName,M.DefaultRate,M.DefaultScale,E.Name,E.Cause,E.Notes,E.StartTime,unix_timestamp(E.StartTime) as Time,E.Length,E.Frames,E.AlarmFrames,E.TotScore,E.AvgScore,E.MaxScore,E.Archived,E.Videoed,E.Uploaded,E.Emailed,E.Messaged,E.Executed from Events as E inner join Monitors as M on M.Id = E.MonitorId where not isnull(E.EndTime)";
        $db_filter->{Sql} = '';

        if ( @{$filter_expr->{terms}} )
        {
            for ( my $i = 0; $i < @{$filter_expr->{terms}}; $i++ )
            {
                if ( exists($filter_expr->{terms}[$i]->{cnj}) )
                {
                    $db_filter->{Sql} .= " ".$filter_expr->{terms}[$i]->{cnj}." ";
                }
                if ( exists($filter_expr->{terms}[$i]->{obr}) )
                {
                    $db_filter->{Sql} .= " ".str_repeat( "(", $filter_expr->{terms}[$i]->{obr} )." ";
                }
                my $value = $filter_expr->{terms}[$i]->{val};
                my @value_list;
                if ( $filter_expr->{terms}[$i]->{attr} )
                {
                    if ( $filter_expr->{terms}[$i]->{attr} =~ /^Monitor/ )
                    {
                        my ( $temp_attr_name ) = $filter_expr->{terms}[$i]->{attr} =~ /^Monitor(.+)$/;
                        $db_filter->{Sql} .= "M.".$temp_attr_name;
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'DateTime' )
                    {
                        $db_filter->{Sql} .= "E.StartTime";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Date' )
                    {
                        $db_filter->{Sql} .= "to_days( E.StartTime )";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Time' )
                    {
                        $db_filter->{Sql} .= "extract( hour_second from E.StartTime )";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Weekday' )
                    {
                        $db_filter->{Sql} .= "weekday( E.StartTime )";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'DiskPercent' )
                    {
                        $db_filter->{Sql} .= "zmDiskPercent";
                        $db_filter->{HasDiskPercent} = !undef;
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'DiskBlocks' )
                    {
                        $db_filter->{Sql} .= "zmDiskBlocks";
                        $db_filter->{HasDiskBlocks} = !undef;
                    }
                    elsif ( $filter_expr->{terms}[$i]->{attr} eq 'SystemLoad' )
                    {
                        $db_filter->{Sql} .= "zmSystemLoad";
                        $db_filter->{HasSystemLoad} = !undef;
                    }
                    else
                    {
                        $db_filter->{Sql} .= "E.".$filter_expr->{terms}[$i]->{attr};
                    }

                    ( my $stripped_value = $value ) =~ s/^["\']+?(.+)["\']+?$/$1/;
                    foreach my $temp_value ( split( /["'\s]*?,["'\s]*?/, $stripped_value ) )
                    {
                        if ( $filter_expr->{terms}[$i]->{attr} =~ /^Monitor/ )
                        {
                            $value = "'$temp_value'";
                        }
                        elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Name' || $filter_expr->{terms}[$i]->{attr} eq 'Cause' || $filter_expr->{terms}[$i]->{attr} eq 'Notes' )
                        {
                            $value = "'$temp_value'";
                        }
                        elsif ( $filter_expr->{terms}[$i]->{attr} eq 'DateTime' )
                        {
                            $value = DateTimeToSQL( $temp_value );
                            if ( !$value )
                            {
                                Error( "Error parsing date/time '$temp_value', skipping filter '$db_filter->{Name}'\n" );
                                next FILTER;
                            }
                            $value = "'$value'";
                        }
                        elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Date' )
                        {
                            $value = DateTimeToSQL( $temp_value );
                            if ( !$value )
                            {
                                Error( "Error parsing date/time '$temp_value', skipping filter '$db_filter->{Name}'\n" );
                                next FILTER;
                            }
                            $value = "to_days( '$value' )";
                        }
                        elsif ( $filter_expr->{terms}[$i]->{attr} eq 'Time' )
                        {
                            $value = DateTimeToSQL( $temp_value );
                            if ( !$value )
                            {
                                Error( "Error parsing date/time '$temp_value', skipping filter '$db_filter->{Name}'\n" );
                                next FILTER;
                            }
                            $value = "extract( hour_second from '$value' )";
                        }
                        else
                        {
                            $value = $temp_value;
                        }
                        push( @value_list, $value );
                    }
                }
                if ( $filter_expr->{terms}[$i]->{op} )
                {
                    if ( $filter_expr->{terms}[$i]->{op} eq '=~' )
                    {
                        $db_filter->{Sql} .= " regexp $value";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{op} eq '!~' )
                    {
                        $db_filter->{Sql} .= " not regexp $value";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{op} eq '=[]' )
                    {
                        $db_filter->{Sql} .= " in (".join( ",", @value_list ).")";
                    }
                    elsif ( $filter_expr->{terms}[$i]->{op} eq '!~' )
                    {
                        $db_filter->{Sql} .= " not in (".join( ",", @value_list ).")";
                    }
                    else
                    {
                        $db_filter->{Sql} .= " ".$filter_expr->{terms}[$i]->{op}." $value";
                    }
                }
                if ( exists($filter_expr->{terms}[$i]->{cbr}) )
                {
                    $db_filter->{Sql} .= " ".str_repeat( ")", $filter_expr->{terms}[$i]->{cbr} )." ";
                }
            }
        }
        if ( $db_filter->{Sql} )
        {
            $sql .= " and ( ".$db_filter->{Sql}." )";
        }
        my @auto_terms;
        if ( $db_filter->{AutoArchive} )
        {
            push( @auto_terms, "E.Archived = 0" )
        }
        if ( $db_filter->{AutoVideo} )
        {
            push( @auto_terms, "E.Videoed = 0" )
        }
        if ( $db_filter->{AutoUpload} )
        {
            push( @auto_terms, "E.Uploaded = 0" )
        }
        if ( $db_filter->{AutoEmail} )
        {
            push( @auto_terms, "E.Emailed = 0" )
        }
        if ( $db_filter->{AutoMessage} )
        {
            push( @auto_terms, "E.Messaged = 0" )
        }
        if ( $db_filter->{AutoExecute} )
        {
            push( @auto_terms, "E.Executed = 0" )
        }
        if ( @auto_terms )
        {
            $sql .= " and ( ".join( " or ", @auto_terms )." )";
        }
        if ( !$filter_expr->{sort_field} )
        {
            $filter_expr->{sort_field} = 'StartTime';
            $filter_expr->{sort_asc} = 0;
        }
        my $sort_column = '';
        if ( $filter_expr->{sort_field} eq 'Id' )
        {
            $sort_column = "E.Id"; 
        }
        elsif ( $filter_expr->{sort_field} eq 'MonitorName' )
        {
            $sort_column = "M.Name";
        }
        elsif ( $filter_expr->{sort_field} eq 'Name' )
        {
            $sort_column = "E.Name";
        }
        elsif ( $filter_expr->{sort_field} eq 'StartTime' )
        {
            $sort_column = "E.StartTime";
        }
        elsif ( $filter_expr->{sort_field} eq 'Secs' )
        {
            $sort_column = "E.Length";
        }
        elsif ( $filter_expr->{sort_field} eq 'Frames' )
        {
            $sort_column = "E.Frames";
        }
        elsif ( $filter_expr->{sort_field} eq 'AlarmFrames' )
        {
            $sort_column = "E.AlarmFrames";
        }
        elsif ( $filter_expr->{sort_field} eq 'TotScore' )
        {
            $sort_column = "E.TotScore";
        }
        elsif ( $filter_expr->{sort_field} eq 'AvgScore' )
        {
            $sort_column = "E.AvgScore";
        }
        elsif ( $filter_expr->{sort_field} eq 'MaxScore' )
        {
            $sort_column = "E.MaxScore";
        }
        else
        {
            $sort_column = "E.StartTime";
        }
        my $sort_order = $filter_expr->{sort_asc}?"asc":"desc";
        $sql .= " order by ".$sort_column." ".$sort_order;
        if ( $filter_expr->{limit} )
        {
            $sql .= " limit 0,".$filter_expr->{limit};
        }
        Debug( "SQL:$sql\n" );
        $db_filter->{Sql} = $sql;
        if ( $db_filter->{AutoExecute} )
        {
            my $script = $db_filter->{AutoExecuteCmd};
            $script =~ s/\s.*$//;
            if ( !-e $script )
            {
                Error( "Auto execute script '$script' not found, skipping filter '$db_filter->{Name}'\n" );
                next FILTER;

            }
            elsif ( !-x $script )
            {
                Error( "Auto execute script '$script' not executable, skipping filter '$db_filter->{Name}'\n" );
                next FILTER;
            }
        }
        push( @filters, $db_filter );
    }
    $sth->finish();

    return( \@filters );
}

sub checkFilter
{
    my $filter = shift;

    Debug( "Checking filter '$filter->{Name}'".
        ($filter->{AutoDelete}?", delete":"").
        ($filter->{AutoArchive}?", archive":"").
        ($filter->{AutoVideo}?", video":"").
        ($filter->{AutoUpload}?", upload":"").
        ($filter->{AutoEmail}?", email":"").
        ($filter->{AutoMessage}?", message":"").
        ($filter->{AutoExecute}?", execute":"").
        "\n"
    );
    my $sql = $filter->{Sql};
    
    if ( $filter->{HasDiskPercent} )
    {
        my $disk_percent = getDiskPercent();
        $sql =~ s/zmDiskPercent/$disk_percent/g;
    }
    if ( $filter->{HasDiskBlocks} )
    {
        my $disk_blocks = getDiskBlocks();
        $sql =~ s/zmDiskBlocks/$disk_blocks/g;
    }
    if ( $filter->{HasSystemLoad} )
    {
        my $load = getLoad();
        $sql =~ s/zmSystemLoad/$load/g;
    }

    my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute();
    if ( !$res )
    {
        Error( "Can't execute filter '$sql', ignoring: ".$sth->errstr() );
        return;
    }

    while( my $event = $sth->fetchrow_hashref() )
    {
        Debug( "Checking event $event->{Id}\n" );
        my $delete_ok = !undef;
        if ( $filter->{AutoArchive} )
        {
            Info( "Archiving event $event->{Id}\n" );
            # Do it individually to avoid locking up the table for new events
            my $sql = "update Events set Archived = 1 where Id = ?";
            my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
        }
        if ( ZM_OPT_FFMPEG && $filter->{AutoVideo} )
        {
            if ( !$event->{Videoed} )
            {
                $delete_ok = undef if ( !generateVideo( $filter, $event ) );
            }
        }
        if ( ZM_OPT_EMAIL && $filter->{AutoEmail} )
        {
            if ( !$event->{Emailed} )
            {
                $delete_ok = undef if ( !sendEmail( $filter, $event ) );
            }
        }
        if ( ZM_OPT_MESSAGE && $filter->{AutoMessage} )
        {
            if ( !$event->{Messaged} )
            {
                $delete_ok = undef if ( !sendMessage( $filter, $event ) );
            }
        }
        if ( ZM_OPT_UPLOAD && $filter->{AutoUpload} )
        {
            if ( !$event->{Uploaded} )
            {
                $delete_ok = undef if ( !uploadArchFile( $filter, $event ) );
            }
        }
        if ( $filter->{AutoExecute} )
        {
            if ( !$event->{Execute} )
            {
                $delete_ok = undef if ( !executeCommand( $filter, $event ) );
            }
        }
        if ( $filter->{AutoDelete} )
        {
            if ( $delete_ok )
            {
                Info( "Deleting event $event->{Id}\n" );
                # Do it individually to avoid locking up the table for new events
                my $sql = "delete from Events where Id = ?";
                my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );

                if ( !ZM_OPT_FAST_DELETE )
                {
                    my $sql = "delete from Frames where EventId = ?";
                    my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
                    my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );

                    $sql = "delete from Stats where EventId = ?";
                    $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
                    $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );

                    deleteEventFiles( $event->{Id}, $event->{MonitorId} );
                }
            }
            else
            {
                Error( "Unable to delete event $event->{Id} as previous operations failed\n" );
            }
        }
    }
    $sth->finish();
}

sub generateVideo
{
    my $filter = shift;
    my $event = shift;
    my $phone = shift;

    my $rate = $event->{DefaultRate}/100;
    my $scale = $event->{DefaultScale}/100;
    my $format;

    my @ffmpeg_formats = split( /\s+/, ZM_FFMPEG_FORMATS );
    my $default_video_format;
    my $default_phone_format;
    foreach my $ffmpeg_format( @ffmpeg_formats )
    {
        if ( $ffmpeg_format =~ /^(.+)\*\*$/ )
        {
            $default_phone_format = $1;
        }
        elsif ( $ffmpeg_format =~ /^(.+)\*$/ )
        {
            $default_video_format = $1;
        }
    }

    if ( $phone && $default_phone_format )
    {
        $format = $default_phone_format;
    }
    elsif ( $default_video_format )
    {
        $format = $default_video_format;
    }
    else
    {
        $format = $ffmpeg_formats[0];
    }

    my $command = ZM_PATH_BIN."/zmvideo.pl -e ".$event->{Id}." -r ".$rate." -s ".$scale." -f ".$format;
    my $output = qx($command);
    chomp( $output );
    my $status = $? >> 8;
    if ( $status || logDebugging() )
    {
        Debug( "Output: $output\n" );
    }
    if ( $status )
    {
        Error( "Video generation '$command' failed with status: $status\n" );
        if ( wantarray() )
        {
            return( undef, undef );
        }
        return( 0 );
    }
    else
    {
        my $sql = "update Events set Videoed = 1 where Id = ?";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
        if ( wantarray() )
        {
            return( $format, sprintf( "%s/%s", getEventPath( $event ), $output ) ); 
        }
    }
    return( 1 );
}

sub uploadArchFile
{
    my $filter = shift;
    my $event = shift;

    if ( !ZM_UPLOAD_HOST )
    {
        Error( "Cannot upload archive as no upload host defined" );
        return( 0 );
    }

    my $archFile = $event->{MonitorName}.'-'.$event->{Id};
    my $archImagePath = getEventPath( $event )."/".((ZM_UPLOAD_ARCH_ANALYSE)?'{*analyse,*capture}':'*capture').".jpg";
    my @archImageFiles = glob($archImagePath);
    my $archLocPath;

    my $archError = 0;
    if ( ZM_UPLOAD_ARCH_FORMAT eq "zip" )
    {
        $archFile .= '.zip';
        $archLocPath = ZM_UPLOAD_LOC_DIR.'/'.$archFile;
        my $zip = Archive::Zip->new();
        Info( "Creating upload file '$archLocPath', ".int(@archImageFiles)." files\n" );

        my $status = &AZ_OK;
        foreach my $imageFile ( @archImageFiles )
        {
            Debug( "Adding $imageFile\n" );
            my $member = $zip->addFile( $imageFile );
            if ( !$member )
            {
                Error( "Unable to add image file $imageFile to zip archive $archLocPath" );
                $archError = 1;
                last;
            }
            $member->desiredCompressionMethod( (ZM_UPLOAD_ARCH_COMPRESS)?&COMPRESSION_DEFLATED:&COMPRESSION_STORED );
        }
        if ( !$archError )
        {
            $status = $zip->writeToFileNamed( $archLocPath );

            if ( $archError = ($status != &AZ_OK) )
            {
                Error( "Zip error: $status\n " );
            }
        }
        else
        {
            Error( "Error adding images to zip archive $archLocPath, not writing" );
        }
    }
    elsif ( ZM_UPLOAD_ARCH_FORMAT eq "tar" )
    {
        if ( ZM_UPLOAD_ARCH_COMPRESS )
        {
            $archFile .= '.tar.gz';
        }
        else
        {
            $archFile .= '.tar';
        }
        $archLocPath = ZM_UPLOAD_LOC_DIR.'/'.$archFile;
        Info( "Creating upload file '$archLocPath', ".int(@archImageFiles)." files\n" );

        if ( $archError = !Archive::Tar->create_archive( $archLocPath, ZM_UPLOAD_ARCH_COMPRESS, @archImageFiles ) )
        {
            Error( "Tar error: ".Archive::Tar->error()."\n " );
        }
    }

    if ( $archError )
    {
        return( 0 );
    }
    else
    {
        if ( ZM_UPLOAD_PROTOCOL eq "ftp" )
        {
            Info( "Uploading to ".ZM_UPLOAD_HOST." using FTP\n" );
            my $ftp = Net::FTP->new( ZM_UPLOAD_HOST, Timeout=>ZM_UPLOAD_TIMEOUT, Passive=>ZM_UPLOAD_FTP_PASSIVE, Debug=>ZM_UPLOAD_DEBUG );
            if ( !$ftp )
            {
                Error( "Can't create FTP connection: $@" );
                return( 0 );
            }
            $ftp->login( ZM_UPLOAD_USER, ZM_UPLOAD_PASS ) or Error( "FTP - Can't login" );
            $ftp->binary() or Error( "FTP - Can't go binary" );
            $ftp->cwd( ZM_UPLOAD_REM_DIR ) or Error( "FTP - Can't cwd" ) if ( ZM_UPLOAD_REM_DIR );
            $ftp->put( $archLocPath ) or Error( "FTP - Can't upload '$archLocPath'" );
            $ftp->quit() or Error( "FTP - Can't quit" );
        }
        else
        {
            my $host = ZM_UPLOAD_HOST;
            $host .= ":".ZM_UPLOAD_PORT if ( ZM_UPLOAD_PORT );
            Info( "Uploading to ".$host." using SFTP\n" );
            my %sftpOptions = ( host=>ZM_UPLOAD_HOST, user=>ZM_UPLOAD_USER );
            $sftpOptions{password} = ZM_UPLOAD_PASS if ( ZM_UPLOAD_PASS );
            $sftpOptions{port} = ZM_UPLOAD_PORT if ( ZM_UPLOAD_PORT );
            $sftpOptions{timeout} = ZM_UPLOAD_TIMEOUT if ( ZM_UPLOAD_TIMEOUT );
            $sftpOptions{more} = [ '-o'=>'StrictHostKeyChecking=no' ];
            $Net::SFTP::Foreign::debug = -1 if ( ZM_UPLOAD_DEBUG );
            my $sftp = Net::SFTP::Foreign->new( ZM_UPLOAD_HOST, %sftpOptions );
            if ( $sftp->error )
            {
                Error( "Can't create SFTP connection: ".$sftp->error );
                return( 0 );
            }
            $sftp->setcwd( ZM_UPLOAD_REM_DIR ) or Error( "SFTP - Can't setcwd: ".$sftp->error ) if ( ZM_UPLOAD_REM_DIR );
            $sftp->put( $archLocPath, $archFile ) or Error( "SFTP - Can't upload '$archLocPath': ".$sftp->error );
        }
        unlink( $archLocPath );
        my $sql = "update Events set Uploaded = 1 where Id = ?";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
    }
    return( 1 );
}

sub substituteTags
{
    my $text = shift;
    my $filter = shift;
    my $event = shift;
    my $attachments_ref = shift;

    # First we'd better check what we need to get
    # We have a filter and an event, do we need any more
    # monitor information?
    my $need_monitor = $text =~ /%(?:MET|MEH|MED|MEW|MEN|MEA)%/;

    my $monitor = {};
    if ( $need_monitor )
    {
        my $db_now = strftime( "%Y-%m-%d %H:%M:%S", localtime() );
        my $sql = "select M.Id, count(E.Id) as EventCount, count(if(E.Archived,1,NULL)) as ArchEventCount, count(if(E.StartTime>'$db_now' - INTERVAL 1 HOUR && E.Archived = 0,1,NULL)) as HourEventCount, count(if(E.StartTime>'$db_now' - INTERVAL 1 DAY && E.Archived = 0,1,NULL)) as DayEventCount, count(if(E.StartTime>'$db_now' - INTERVAL 7 DAY && E.Archived = 0,1,NULL)) as WeekEventCount, count(if(E.StartTime>'$db_now' - INTERVAL 1 MONTH && E.Archived = 0,1,NULL)) as MonthEventCount from Monitors as M left join Events as E on E.MonitorId = M.Id where MonitorId = ? group by E.MonitorId order by Id";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $event->{MonitorId} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
        $monitor = $sth->fetchrow_hashref();
        $sth->finish();
        return() if ( !$monitor );
    }

    # Do we need the image information too?
    my $need_images = $text =~ /%(?:EPI1|EPIM|EI1|EIM)%/;
    my $first_alarm_frame;
    my $max_alarm_frame;
    my $max_alarm_score = 0;
    if ( $need_images )
    {
        my $sql = "select * from Frames where EventId = ? and Type = 'Alarm' order by FrameId";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
        while( my $frame = $sth->fetchrow_hashref() )
        {
            if ( !$first_alarm_frame )
            {
                $first_alarm_frame = $frame;
            }
            if ( $frame->{Score} > $max_alarm_score )
            {
                $max_alarm_frame = $frame;
                $max_alarm_score = $frame->{Score};
            }
        }
        $sth->finish();
    }

    my $url = ZM_URL;
    $text =~ s/%ZP%/$url/g;
    $text =~ s/%MN%/$event->{MonitorName}/g;
    $text =~ s/%MET%/$monitor->{EventCount}/g;
    $text =~ s/%MEH%/$monitor->{HourEventCount}/g;
    $text =~ s/%MED%/$monitor->{DayEventCount}/g;
    $text =~ s/%MEW%/$monitor->{WeekEventCount}/g;
    $text =~ s/%MEM%/$monitor->{MonthEventCount}/g;
    $text =~ s/%MEA%/$monitor->{ArchEventCount}/g;
    $text =~ s/%MP%/$url?view=watch&mid=$event->{MonitorId}/g;
    $text =~ s/%MPS%/$url?view=watchfeed&mid=$event->{MonitorId}&mode=stream/g;
    $text =~ s/%MPI%/$url?view=watchfeed&mid=$event->{MonitorId}&mode=still/g;
    $text =~ s/%EP%/$url?view=event&mid=$event->{MonitorId}&eid=$event->{Id}/g;
    $text =~ s/%EPS%/$url?view=event&mode=stream&mid=$event->{MonitorId}&eid=$event->{Id}/g;
    $text =~ s/%EPI%/$url?view=event&mode=still&mid=$event->{MonitorId}&eid=$event->{Id}/g;
    $text =~ s/%EI%/$event->{Id}/g;
    $text =~ s/%EN%/$event->{Name}/g;
    $text =~ s/%EC%/$event->{Cause}/g;
    $text =~ s/%ED%/$event->{Notes}/g;
    $text =~ s/%ET%/$event->{StartTime}/g;
    $text =~ s/%EL%/$event->{Length}/g;
    $text =~ s/%EF%/$event->{Frames}/g;
    $text =~ s/%EFA%/$event->{AlarmFrames}/g;
    $text =~ s/%EST%/$event->{TotScore}/g;
    $text =~ s/%ESA%/$event->{AvgScore}/g;
    $text =~ s/%ESM%/$event->{MaxScore}/g;
    if ( $first_alarm_frame )
    {
        $text =~ s/%EPI1%/$url?view=frame&mid=$event->{MonitorId}&eid=$event->{Id}&fid=$first_alarm_frame->{FrameId}/g;
        $text =~ s/%EPIM%/$url?view=frame&mid=$event->{MonitorId}&eid=$event->{Id}&fid=$max_alarm_frame->{FrameId}/g;
        if ( $attachments_ref && $text =~ s/%EI1%//g )
        {
            push( @$attachments_ref, { type=>"image/jpeg", path=>sprintf( "%s/%0".ZM_EVENT_IMAGE_DIGITS."d-capture.jpg", getEventPath( $event ), $first_alarm_frame->{FrameId} ) } );
        }
        if ( $attachments_ref && $text =~ s/%EIM%//g )
        {
            # Don't attach the same image twice
            if ( !@$attachments_ref || ($first_alarm_frame->{FrameId} != $max_alarm_frame->{FrameId} ) )
            {
                push( @$attachments_ref, { type=>"image/jpeg", path=>sprintf( "%s/%0".ZM_EVENT_IMAGE_DIGITS."d-capture.jpg", getEventPath( $event ), $max_alarm_frame->{FrameId} ) } );
            }
        }
    }
    if ( $attachments_ref && ZM_OPT_FFMPEG )
    {
        if ( $text =~ s/%EV%//g )
        {
            my ( $format, $path ) = generateVideo( $filter, $event );
            if ( !$format )
            {
                return( undef );
            }
            push( @$attachments_ref, { type=>"video/$format", path=>$path } );
        }
        if ( $text =~ s/%EVM%//g )
        {
            my ( $format, $path ) = generateVideo( $filter, $event, 1 );
            if ( !$format )
            {
                return( undef );
            }
            push( @$attachments_ref, { type=>"video/$format", path=>$path } );
        }
    }
    $text =~ s/%FN%/$filter->{Name}/g;
    ( my $filter_name = $filter->{Name} ) =~ s/ /+/g;
    $text =~ s/%FP%/$url?view=filter&mid=$event->{MonitorId}&filter_name=$filter_name/g;
    
    return( $text );
}

sub sendEmail
{
    my $filter = shift;
    my $event = shift;

    if ( !ZM_FROM_EMAIL )
    {
        Error( "No 'from' email address defined, not sending email" );
        return( 0 );
    }
    if ( !ZM_EMAIL_ADDRESS )
    {
        Error( "No email address defined, not sending email" );
        return( 0 );
    }

    Info( "Creating notification email\n" );

    my $subject = substituteTags( ZM_EMAIL_SUBJECT, $filter, $event );
    return( 0 ) if ( !$subject );
    my @attachments;
    my $body = substituteTags( ZM_EMAIL_BODY, $filter, $event, \@attachments );
    return( 0 ) if ( !$body );

    Info( "Sending notification email '$subject'\n" );

    eval
    {
        if ( ZM_NEW_MAIL_MODULES )
        {
            ### Create the multipart container
            my $mail = MIME::Lite->new (
                From => ZM_FROM_EMAIL,
                To => ZM_EMAIL_ADDRESS,
                Subject => $subject,
                Type => "multipart/mixed"
            );
            ### Add the text message part
            $mail->attach (
                Type => "TEXT",
                Data => $body
            );
            ### Add the attachments
            foreach my $attachment ( @attachments )
            {
                Info( "Attaching '$attachment->{path}\n" );
                $mail->attach(
                    Path => $attachment->{path},
                    Type => $attachment->{type},
                    Disposition => "attachment"
                );
            }
            ### Send the Message
            MIME::Lite->send( "smtp", ZM_EMAIL_HOST, Timeout=>60 );
            $mail->send();
        } 
        else
        {
            my $mail = MIME::Entity->build(
                From => ZM_FROM_EMAIL,
                To => ZM_EMAIL_ADDRESS,
                Subject => $subject,
                Type => (($body=~/<html>/)?'text/html':'text/plain'),
                Data => $body
            );

            foreach my $attachment ( @attachments )
            {
                Info( "Attaching '$attachment->{path}\n" );
                $mail->attach(
                    Path => $attachment->{path},
                    Type => $attachment->{type},
                    Encoding => "base64"
                );
            }
            $mail->smtpsend( Host => ZM_EMAIL_HOST, MailFrom => ZM_FROM_EMAIL );
        }
    };
    if ( $@ )
    {
        Error( "Can't send email: $@" );
        return( 0 );
    }
    else
    {
        Info( "Notification email sent\n" );
    }
    my $sql = "update Events set Emailed = 1 where Id = ?";
    my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );

    return( 1 );
}

sub sendMessage
{
    my $filter = shift;
    my $event = shift;

    if ( !ZM_FROM_EMAIL )
    {
        Error( "No 'from' email address defined, not sending message" );
        return( 0 );
    }
    if ( !ZM_MESSAGE_ADDRESS )
    {
        Error( "No message address defined, not sending message" );
        return( 0 );
    }

    Info( "Creating notification message\n" );

    my $subject = substituteTags( ZM_MESSAGE_SUBJECT, $filter, $event );
    return( 0 ) if ( !$subject );
    my @attachments;
    my $body = substituteTags( ZM_MESSAGE_BODY, $filter, $event, \@attachments );
    return( 0 ) if ( !$body );

    Info( "Sending notification message '$subject'\n" );

    eval
    {
        if ( ZM_NEW_MAIL_MODULES )
        {
            ### Create the multipart container
            my $mail = MIME::Lite->new (
                From => ZM_FROM_EMAIL,
                To => ZM_MESSAGE_ADDRESS,
                Subject => $subject,
                Type => "multipart/mixed"
            );
            ### Add the text message part
            $mail->attach (
                Type => "TEXT",
                Data => $body
            );
            ### Add the attachments
            foreach my $attachment ( @attachments )
            {
                Info( "Attaching '$attachment->{path}\n" );
                $mail->attach(
                    Path => $attachment->{path},
                    Type => $attachment->{type},
                    Disposition => "attachment"
                );
            }
            ### Send the Message
            MIME::Lite->send( "smtp", ZM_EMAIL_HOST, Timeout=>60 );
            $mail->send();
        } 
        else
        {
            my $mail = MIME::Entity->build(
                From => ZM_FROM_EMAIL,
                To => ZM_MESSAGE_ADDRESS,
                Subject => $subject,
                Type => (($body=~/<html>/)?'text/html':'text/plain'),
                Data => $body
            );

            foreach my $attachment ( @attachments )
            {
                Info( "Attaching '$attachment->{path}\n" );
                $mail->attach(
                    Path => $attachment->{path},
                    Type => $attachment->{type},
                    Encoding => "base64"
                );
            }
            $mail->smtpsend( Host => ZM_EMAIL_HOST, MailFrom => ZM_FROM_EMAIL );
        }
    };
    if ( $@ )
    {
        Error( "Can't send email: $@" );
        return( 0 );
    }
    else
    {
        Info( "Notification message sent\n" );
    }
    my $sql = "update Events set Messaged = 1 where Id = ?";
    my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );

    return( 1 );
}

sub executeCommand
{
    my $filter = shift;
    my $event = shift;

    my $event_path = getEventPath( $event );

    my $command = $filter->{AutoExecuteCmd};
    $command .= " $event_path";

    Info( "Executing '$command'\n" );
    my $output = qx($command);
    my $status = $? >> 8;
    if ( $status || logDebugging() )
    {
        chomp( $output );
        Debug( "Output: $output\n" );
    }
    if ( $status )
    {
        Error( "Command '$command' exited with status: $status\n" );
        return( 0 );
    }
    else
    {
        my $sql = "update Events set Executed = 1 where Id = ?";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( $event->{Id} ) or Fatal( "Can't execute '$sql': ".$sth->errstr() );
    }
    return( 1 );
}

