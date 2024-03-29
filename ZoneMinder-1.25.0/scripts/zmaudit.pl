#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Audit Script, $Date: 2011-08-26 10:51:13 +0100 (Fri, 26 Aug 2011) $, $Revision: 3508 $
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
# This script checks for consistency between the event filesystem and
# the database. If events are found in one and not the other they are
# deleted (optionally). Additionally any monitor event directories that
# do not correspond to a database monitor are similarly disposed of.
# However monitors in the database that don't have a directory are left
# alone as this is valid if they are newly created and have no events
# yet.
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant MIN_AGE => 300; # Minimum age when we will delete anything
use constant MAX_AGED_DIRS => 10; # Number of event dirs to check age on
use constant RECOVER_TAG => "(r)"; # Tag to append to event name when recovered
use constant RECOVER_TEXT => "Recovered."; # Text to append to event notes when recovered

# ==========================================================================
#
# You shouldn't need to change anything from here downwards
#
# ==========================================================================

# Include from system perl paths only
use ZoneMinder;
use DBI;
use POSIX;
use File::Find;
use Time::HiRes qw/gettimeofday/;
use Getopt::Long;

use constant IMAGE_PATH => ZM_PATH_WEB.'/'.ZM_DIR_IMAGES;
use constant EVENT_PATH => (ZM_DIR_EVENTS=~m|/|)?ZM_DIR_EVENTS:(ZM_PATH_WEB.'/'.ZM_DIR_EVENTS);

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $report = 0;
my $interactive = 0;
my $continuous = 0;

sub usage
{
    print( "
Usage: zmaudit.pl [-r,-report|-i,-interactive]
Parameters are :-
-r, --report                    - Just report don't actually do anything
-i, --interactive               - Ask before applying any changes
-c, --continuous                - Run continuously
");
    exit( -1 );
}

sub aud_print( $ );
sub confirm( ;$$ );
sub deleteSwapImage();

logInit();
logSetSignal();

if ( !GetOptions( 'report'=>\$report, 'interactive'=>\$interactive, 'continuous'=>\$continuous ) )
{
    usage();
}

if ( ($report + $interactive + $continuous) > 1 )
{
    print( STDERR "Error, only option may be specified\n" );
    usage();
}

my $dbh = zmDbConnect();

chdir( EVENT_PATH );

my $max_image_age = 6/24; # 6 hours
my $max_swap_age = 24/24; # 24 hours
my $image_path = IMAGE_PATH;
my $swap_image_path = ZM_PATH_SWAP;

my $loop = 1;
my $cleaned = 0;
MAIN: while( $loop )
{
    my $db_monitors;
    my $monitorSelectSql = "select Id from Monitors order by Id";
    my $monitorSelectSth = $dbh->prepare_cached( $monitorSelectSql ) or Fatal( "Can't prepare '$monitorSelectSql': ".$dbh->errstr() );
    my $eventSelectSql = "select Id, (unix_timestamp() - unix_timestamp(StartTime)) as Age from Events where MonitorId = ? order by Id";
    my $eventSelectSth = $dbh->prepare_cached( $eventSelectSql ) or Fatal( "Can't prepare '$eventSelectSql': ".$dbh->errstr() );

    $cleaned = 0;
    my $res = $monitorSelectSth->execute() or Fatal( "Can't execute: ".$monitorSelectSth->errstr() );
    while( my $monitor = $monitorSelectSth->fetchrow_hashref() )
    {
        Debug( "Found database monitor '$monitor->{Id}'" );
        my $db_events = $db_monitors->{$monitor->{Id}} = {};
        my $res = $eventSelectSth->execute( $monitor->{Id} ) or Fatal( "Can't execute: ".$eventSelectSth->errstr() );
        while ( my $event = $eventSelectSth->fetchrow_hashref() )
        {
            $db_events->{$event->{Id}} = $event->{Age};
        }
        Debug( "Got ".int(keys(%$db_events))." events\n" );
        $eventSelectSth->finish();
    }
    $monitorSelectSth->finish();

    my $fs_monitors;
    foreach my $monitor ( <[0-9]*> )
    {
        Debug( "Found filesystem monitor '$monitor'" );
        my $fs_events = $fs_monitors->{$monitor} = {};
        ( my $monitor_dir ) = ( $monitor =~ /^(.*)$/ ); # De-taint

        if ( ZM_USE_DEEP_STORAGE )
        {
            foreach my $day_dir ( <$monitor_dir/*/*/*> )
            {
                Debug( "Checking $day_dir" );
                ( $day_dir ) = ( $day_dir =~ /^(.*)$/ ); # De-taint
                chdir( $day_dir );
                opendir( DIR, "." ) or Fatal( "Can't open directory '$day_dir': $!" );
                my @event_links = sort { $b <=> $a } grep { -l $_ } readdir( DIR );
                closedir( DIR );
                my $count = 0;
                foreach my $event_link ( @event_links )
                {
                    Debug( "Checking link $event_link" );
                    ( my $event = $event_link ) =~ s/^.*\.//;
                    my $event_path = readlink( $event_link );
                    if ( $count++ > MAX_AGED_DIRS )
                    {
                        $fs_events->{$event} = -1;
                    }
                    else
                    {
                        if ( !-e $event_path )
                        {
                            aud_print( "Event link $day_dir/$event_link does not point to valid target" );
                            if ( confirm() )
                            {
                                ( $event_link ) = ( $event_link =~ /^(.*)$/ ); # De-taint
                                unlink( $event_link );
                                $cleaned = 1;
                            }
                        }
                        else
                        {
                            $fs_events->{$event} = (time() - ($^T - ((-M $event_path) * 24*60*60)));
                        }
                    }
                }
                chdir( EVENT_PATH );
            }
        }
        else
        {
            chdir( $monitor_dir );
            opendir( DIR, "." ) or Fatal( "Can't open directory '$monitor_dir': $!" );
            my @temp_events = sort { $b <=> $a } grep { -d $_ && $_ =~ /^\d+$/ } readdir( DIR );
            closedir( DIR );
            my $count = 0;
            foreach my $event ( @temp_events )
            {
                if ( $count++ > MAX_AGED_DIRS )
                {
                    $fs_events->{$event} = -1;
                }
                else
                {
                    $fs_events->{$event} = (time() - ($^T - ((-M $event) * 24*60*60)));
                }
            }
            chdir( EVENT_PATH );
        }
        Debug( "Got ".int(keys(%$fs_events))." events\n" );
    }
    redo MAIN if ( $cleaned );

    $cleaned = 0;
    while ( my ( $fs_monitor, $fs_events ) = each(%$fs_monitors) )
    {
        if ( my $db_events = $db_monitors->{$fs_monitor} )
        {
            if ( $fs_events )
            {
                while ( my ( $fs_event, $age ) = each(%$fs_events ) )
                {
                    if ( !defined($db_events->{$fs_event}) && ($age < 0 || ($age > MIN_AGE)) )
                    {
                        aud_print( "Filesystem event '$fs_monitor/$fs_event' does not exist in database" );
                        if ( confirm() )
                        {
                            deleteEventFiles( $fs_event, $fs_monitor );
                            $cleaned = 1;
                        }
                    }
                }
            }
        }
        else
        {
            aud_print( "Filesystem monitor '$fs_monitor' does not exist in database" );
            if ( confirm() )
            {
                my $command = "rm -rf $fs_monitor";
                executeShellCommand( $command );
                $cleaned = 1;
            }
        }
    }

    my $monitor_links;
    foreach my $link ( <*> )
    {
        next if ( !-l $link );
        next if ( -e $link );

        aud_print( "Filesystem monitor link '$link' does not point to valid monitor directory" );
        if ( confirm() )
        {
            ( $link ) = ( $link =~ /^(.*)$/ ); # De-taint
            my $command = "rm $link";
            executeShellCommand( $command );
            $cleaned = 1;
        }
    }
    redo MAIN if ( $cleaned );

    $cleaned = 0;
    my $deleteMonitorSql = "delete low_priority from Monitors where Id = ?";
    my $deleteMonitorSth = $dbh->prepare_cached( $deleteMonitorSql ) or Fatal( "Can't prepare '$deleteMonitorSql': ".$dbh->errstr() );
    my $deleteEventSql = "delete low_priority from Events where Id = ?";
    my $deleteEventSth = $dbh->prepare_cached( $deleteEventSql ) or Fatal( "Can't prepare '$deleteEventSql': ".$dbh->errstr() );
    my $deleteFramesSql = "delete low_priority from Frames where EventId = ?";
    my $deleteFramesSth = $dbh->prepare_cached( $deleteFramesSql ) or Fatal( "Can't prepare '$deleteFramesSql': ".$dbh->errstr() );
    my $deleteStatsSql = "delete low_priority from Stats where EventId = ?";
    my $deleteStatsSth = $dbh->prepare_cached( $deleteStatsSql ) or Fatal( "Can't prepare '$deleteStatsSql': ".$dbh->errstr() );
    while ( my ( $db_monitor, $db_events ) = each(%$db_monitors) )
    {
        if ( my $fs_events = $fs_monitors->{$db_monitor} )
        {
            if ( $db_events )
            {
                while ( my ( $db_event, $age ) = each(%$db_events ) )
                {
                    if ( !defined($fs_events->{$db_event}) && ($age > MIN_AGE) )
                    {
                        aud_print( "Database event '$db_monitor/$db_event' does not exist in filesystem" );
                        if ( confirm() )
                        {
                            my $res = $deleteEventSth->execute( $db_event ) or Fatal( "Can't execute: ".$deleteEventSth->errstr() );
                            $res = $deleteFramesSth->execute( $db_event ) or Fatal( "Can't execute: ".$deleteFramesSth->errstr() );
                            $res = $deleteStatsSth->execute( $db_event ) or Fatal( "Can't execute: ".$deleteStatsSth->errstr() );
                            $cleaned = 1;
                        }
                    }
                }
            }
        }
        else
        {
            #aud_print( "Database monitor '$db_monitor' does not exist in filesystem" );
            #if ( confirm() )
            #{
                # We don't actually do this in case it's new
                #my $res = $deleteMonitorSth->execute( $db_monitor ) or Fatal( "Can't execute: ".$deleteMonitorSth->errstr() );
                #$cleaned = 1;
            #}
        }
    }
    redo MAIN if ( $cleaned );

    # Remove orphaned events (with no monitor)
    $cleaned = 0;
    my $selectOrphanedEventsSql = "select Events.Id, Events.Name from Events left join Monitors on (Events.MonitorId = Monitors.Id) where isnull(Monitors.Id)";
    my $selectOrphanedEventsSth = $dbh->prepare_cached( $selectOrphanedEventsSql ) or Fatal( "Can't prepare '$selectOrphanedEventsSql': ".$dbh->errstr() );
    $res = $selectOrphanedEventsSth->execute() or Fatal( "Can't execute: ".$selectOrphanedEventsSth->errstr() );
    while( my $event = $selectOrphanedEventsSth->fetchrow_hashref() )
    {
        aud_print( "Found orphaned event with no monitor '$event->{Id}'" );
        if ( confirm() )
        {
            $res = $deleteEventSth->execute( $event->{Id} ) or Fatal( "Can't execute: ".$deleteEventSth->errstr() );
            $cleaned = 1;
        }
    }
    $selectOrphanedEventsSth->finish();
    redo MAIN if ( $cleaned );

    # Remove empty events (with no frames)
    $cleaned = 0;
    my $selectEmptyEventsSql = "select * from Events as E left join Frames as F on (E.Id = F.EventId) where isnull(F.EventId) and now() - interval ".MIN_AGE." second > E.StartTime";
    my $selectEmptyEventsSth = $dbh->prepare_cached( $selectEmptyEventsSql ) or Fatal( "Can't prepare '$selectEmptyEventsSql': ".$dbh->errstr() );
    $res = $selectEmptyEventsSth->execute() or Fatal( "Can't execute: ".$selectEmptyEventsSth->errstr() );
    while( my $event = $selectEmptyEventsSth->fetchrow_hashref() )
    {
        aud_print( "Found empty event with no frame records '$event->{Id}'" );
        if ( confirm() )
        {
            $res = $deleteEventSth->execute( $event->{Id} ) or Fatal( "Can't execute: ".$deleteEventSth->errstr() );
            $cleaned = 1;
        }
    }
    $selectEmptyEventsSth->finish();
    redo MAIN if ( $cleaned );

    # Remove orphaned frame records
    $cleaned = 0;
    my $selectOrphanedFramesSql = "select distinct EventId from Frames where EventId not in (select Id from Events)";
    my $selectOrphanedFramesSth = $dbh->prepare_cached( $selectOrphanedFramesSql ) or Fatal( "Can't prepare '$selectOrphanedFramesSql': ".$dbh->errstr() );
    $res = $selectOrphanedFramesSth->execute() or Fatal( "Can't execute: ".$selectOrphanedFramesSth->errstr() );
    while( my $frame = $selectOrphanedFramesSth->fetchrow_hashref() )
    {
        aud_print( "Found orphaned frame records for event '$frame->{EventId}'" );
        if ( confirm() )
        {
            $res = $deleteFramesSth->execute( $frame->{EventId} ) or Fatal( "Can't execute: ".$deleteFramesSth->errstr() );
            $cleaned = 1;
        }
    }
    $selectOrphanedFramesSth->finish();
    redo MAIN if ( $cleaned );

    # Remove orphaned stats records
    $cleaned = 0;
    my $selectOrphanedStatsSql = "select distinct EventId from Stats where EventId not in (select Id from Events)";
    my $selectOrphanedStatsSth = $dbh->prepare_cached( $selectOrphanedStatsSql ) or Fatal( "Can't prepare '$selectOrphanedStatsSql': ".$dbh->errstr() );
    $res = $selectOrphanedStatsSth->execute() or Fatal( "Can't execute: ".$selectOrphanedStatsSth->errstr() );
    while( my $stat = $selectOrphanedStatsSth->fetchrow_hashref() )
    {
        aud_print( "Found orphaned statistic records for event '$stat->{EventId}'" );
        if ( confirm() )
        {
            $res = $deleteStatsSth->execute( $stat->{EventId} ) or Fatal( "Can't execute: ".$deleteStatsSth->errstr() );
            $cleaned = 1;
        }
    }
    $selectOrphanedStatsSth->finish();
    redo MAIN if ( $cleaned );

    # New audit to close any events that were left open for longer than MIN_AGE seconds
    my $selectUnclosedEventsSql = "select E.Id, max(F.TimeStamp) as EndTime, unix_timestamp(max(F.TimeStamp)) - unix_timestamp(E.StartTime) as Length, max(F.FrameId) as Frames, count(if(F.Score>0,1,NULL)) as AlarmFrames, sum(F.Score) as TotScore, max(F.Score) as MaxScore, M.EventPrefix as Prefix from Events as E left join Monitors as M on E.MonitorId = M.Id inner join Frames as F on E.Id = F.EventId where isnull(E.Frames) or isnull(E.EndTime) group by E.Id having EndTime < (now() - interval ".MIN_AGE." second)"; 
    my $selectUnclosedEventsSth = $dbh->prepare_cached( $selectUnclosedEventsSql ) or Fatal( "Can't prepare '$selectUnclosedEventsSql': ".$dbh->errstr() );
    my $updateUnclosedEventsSql = "update low_priority Events set Name = ?, EndTime = ?, Length = ?, Frames = ?, AlarmFrames = ?, TotScore = ?, AvgScore = ?, MaxScore = ?, Notes = concat_ws( ' ', Notes, ? ) where Id = ?";
    my $updateUnclosedEventsSth = $dbh->prepare_cached( $updateUnclosedEventsSql ) or Fatal( "Can't prepare '$updateUnclosedEventsSql': ".$dbh->errstr() );
    $res = $selectUnclosedEventsSth->execute() or Fatal( "Can't execute: ".$selectUnclosedEventsSth->errstr() );
    while( my $event = $selectUnclosedEventsSth->fetchrow_hashref() )
    {
        aud_print( "Found open event '$event->{Id}'" );
        if ( confirm( 'close', 'closing' ) )
        {
            $res = $updateUnclosedEventsSth->execute( sprintf( "%s%d%s", $event->{Prefix}, $event->{Id}, RECOVER_TAG ), $event->{EndTime}, $event->{Length}, $event->{Frames}, $event->{AlarmFrames}, $event->{TotScore}, $event->{AlarmFrames}?int($event->{TotScore}/$event->{AlarmFrames}):0, $event->{MaxScore}, RECOVER_TEXT, $event->{Id} ) or Fatal( "Can't execute: ".$updateUnclosedEventsSth->errstr() );
        }
    }
    $selectUnclosedEventsSth->finish();

    # Now delete any old image files
    if ( my @old_files = grep { -M > $max_image_age } <$image_path/*.{jpg,gif,wbmp}> )
    {
        aud_print( "Deleting ".int(@old_files)." old images\n" );
        my $untainted_old_files = join( ";", @old_files );
        ( $untainted_old_files ) = ( $untainted_old_files =~ /^(.*)$/ );
        unlink( split( /;/, $untainted_old_files ) );
    }

    # Now delete any old swap files
    ( my $swap_image_root ) = ( $swap_image_path =~ /^(.*)$/ ); # De-taint
    File::Find::find( { wanted=>\&deleteSwapImage, untaint=>1 }, $swap_image_root );

    # Prune the Logs table if required
    if ( ZM_LOG_DATABASE_LIMIT )
    {
        if ( ZM_LOG_DATABASE_LIMIT =~ /^\d+$/ )
        {
            # Number of rows
            my $selectLogRowCountSql = "select count(*) as Rows from Logs";
            my $selectLogRowCountSth = $dbh->prepare_cached( $selectLogRowCountSql ) or Fatal( "Can't prepare '$selectLogRowCountSql': ".$dbh->errstr() );
            $res = $selectLogRowCountSth->execute() or Fatal( "Can't execute: ".$selectLogRowCountSth->errstr() );
            my $row = $selectLogRowCountSth->fetchrow_hashref();
            my $logRows = $row->{Rows};
            $selectLogRowCountSth->finish();
            if ( $logRows > ZM_LOG_DATABASE_LIMIT )
            {
                my $deleteLogByRowsSql = "delete low_priority from Logs order by TimeKey asc limit ?";
                my $deleteLogByRowsSth = $dbh->prepare_cached( $deleteLogByRowsSql ) or Fatal( "Can't prepare '$deleteLogByRowsSql': ".$dbh->errstr() );
                $res = $deleteLogByRowsSth->execute( $logRows - ZM_LOG_DATABASE_LIMIT ) or Fatal( "Can't execute: ".$deleteLogByRowsSth->errstr() );
                aud_print( "Deleted ".$deleteLogByRowsSth->rows()." log table entries by count\n" ) if ( $deleteLogByRowsSth->rows() );
            }
        }
        else
        {
            # Time of record
            my $deleteLogByTimeSql = "delete low_priority from Logs where TimeKey < unix_timestamp(now() - interval ".ZM_LOG_DATABASE_LIMIT.")";
            my $deleteLogByTimeSth = $dbh->prepare_cached( $deleteLogByTimeSql ) or Fatal( "Can't prepare '$deleteLogByTimeSql': ".$dbh->errstr() );
            $res = $deleteLogByTimeSth->execute() or Fatal( "Can't execute: ".$deleteLogByTimeSth->errstr() );
            aud_print( "Deleted ".$deleteLogByTimeSth->rows()." log table entries by time\n" ) if ( $deleteLogByTimeSth->rows() );
        }
    }
    $loop = $continuous;

    sleep( ZM_AUDIT_CHECK_INTERVAL ) if ( $continuous );
};

exit( 0 );

sub aud_print( $ )
{
    my $string = shift;
    if ( !$continuous )
    {
        print( $string );
    }
    else
    {
        Info( $string );
    }
}

sub confirm( ;$$ )
{
    my $prompt = shift || "delete";
    my $action = shift || "deleting";

    my $yesno = 0;
    if ( $report )
    {
        print( "\n" );
    }
    elsif ( $interactive )
    {
        print( ", $prompt y/n: " );
        my $char = <>;
        chomp( $char );
        if ( $char eq 'q' )
        {
            exit( 0 );
        }
        if ( !$char )
        {
            $char = 'y';
        }
        $yesno = ( $char =~ /[yY]/ );
    }
    else
    {
        if ( !$continuous )
        {
            print( ", $action\n" );
        }
        else
        {
            Info( $action );
        }
        $yesno = 1;
    }
    return( $yesno );
}

sub deleteSwapImage()
{
    my $file = $_;

    if ( $file !~ /^zmswap-/ )
    {
        return;
    }

    # Ignore directories
    if ( -d $file )
    {
        return;
    }

    if ( -M $file > $max_swap_age )
    {
        Debug( "Deleting $file" );
        #unlink( $file );
    }
}
