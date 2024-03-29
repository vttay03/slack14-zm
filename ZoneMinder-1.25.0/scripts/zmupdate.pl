#!/usr/bin/perl -w
#
# ==========================================================================
#
# ZoneMinder Update Script, $Date: 2011-08-26 08:51:36 +0100 (Fri, 26 Aug 2011) $, $Revision: 3505 $
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
# This script just checks what the most recent release of ZoneMinder is
# at the the moment. It will eventually be responsible for applying and
# configuring upgrades etc, including on the fly upgrades.
#
use strict;
use bytes;

# ==========================================================================
#
# These are the elements you can edit to suit your installation
#
# ==========================================================================

use constant CHECK_INTERVAL => (1*24*60*60); # Interval between version checks

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================

# Include from system perl paths only
use ZoneMinder::Base qw(:all);
use ZoneMinder::Config qw(:all);
use ZoneMinder::Logger qw(:all);
use ZoneMinder::General qw(:all);
use ZoneMinder::Database qw(:all);
use ZoneMinder::ConfigAdmin qw( :functions );
use POSIX;
use DBI;
use Getopt::Long;
use Data::Dumper;

use constant EVENT_PATH => (ZM_DIR_EVENTS=~m|/|)?ZM_DIR_EVENTS:(ZM_PATH_WEB.'/'.ZM_DIR_EVENTS);

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin:/usr/local/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

my $web_uid = (getpwnam( ZM_WEB_USER ))[2];
my $use_log = (($> == 0) || ($> == $web_uid));

logInit( toFile=>$use_log?DEBUG:NOLOG );
logSetSignal();

my $interactive = 1;
my $check = 0;
my $freshen = 0;
my $rename = 0;
my $zoneFix = 0;
my $migrateEvents = 0;
my $version = '';
my $dbUser = ZM_DB_USER;
my $dbPass = ZM_DB_PASS;
my $updateDir = '';
sub Usage
{
    print( "
Usage: zmupdate.pl <-c,--check|-f,--freshen|-v<version>,--version=<version>> [-u<dbuser> -p<dbpass>]>
Parameters are :-
-c, --check                      - Check for updated versions of ZoneMinder
-f, --freshen                    - Freshen the configuration in the database. Equivalent of old zmconfig.pl -noi
-v<version>, --version=<version> - Force upgrade to the current version from <version>
-u<dbuser>, --user=<dbuser>      - Alternate DB user with privileges to alter DB
-p<dbpass>, --pass=<dbpass>      - Password of alternate DB user with privileges to alter DB
-d<dir>,--dir=<dir>              - Directory containing update files if not in default build location
");
    exit( -1 );
}

if ( !GetOptions( 'check'=>\$check, 'freshen'=>\$freshen, 'rename'=>\$rename, 'zone-fix'=>\$zoneFix, 'migrate-events'=>\$migrateEvents, 'version=s'=>\$version, 'interactive!'=>\$interactive, 'user:s'=>\$dbUser, 'pass:s'=>\$dbPass, 'dir:s'=>\$updateDir ) )
{
    Usage();
}

if ( ! ($check || $freshen || $rename || $zoneFix || $migrateEvents || $version) )
{
    if ( ZM_DYN_DB_VERSION )
    {
        $version = ZM_DYN_DB_VERSION;
    }
    else
    {
        print( STDERR "Please give a valid option\n" );
        Usage();
    }
}

if ( ($check + $freshen + $rename + $zoneFix + $migrateEvents + ($version?1:0)) > 1 )
{
    print( STDERR "Please give only one option\n" );
    Usage();
}

if ( $check && ZM_CHECK_FOR_UPDATES )
{
    print( "Update agent starting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );

    my $dbh = zmDbConnect();

    my $currVersion = ZM_DYN_CURR_VERSION;
    my $lastVersion = ZM_DYN_LAST_VERSION;
    my $lastCheck = ZM_DYN_LAST_CHECK;

    if ( !$currVersion )
    {
        $currVersion = ZM_VERSION;

        my $sql = "update Config set Value = ? where Name = 'ZM_DYN_CURR_VERSION'";
        my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( "$currVersion" ) or die( "Can't execute: ".$sth->errstr() );
    }
    zmDbDisconnect();

    while( 1 )
    {
        my $now = time();
        if ( !$lastVersion || !$lastCheck || (($now-$lastCheck) > CHECK_INTERVAL) )
        {
            $dbh = zmDbConnect();

            Info( "Checking for updates\n" );

            use LWP::UserAgent;
            my $ua = LWP::UserAgent->new;
            $ua->agent( "ZoneMinder Update Agent/".ZM_VERSION );
            if ( eval('defined(ZM_UPDATE_CHECK_PROXY)') )
            {
                no strict 'subs';
                if ( ZM_UPDATE_CHECK_PROXY )
                {
                    $ua->proxy( "http", ZM_UPDATE_CHECK_PROXY );
                }
                use strict 'subs';
            }
            my $req = HTTP::Request->new( GET=>'http://www.zoneminder.com/version' );
            my $res = $ua->request($req);

            if ( $res->is_success )
            {
                $lastVersion = $res->content;
                chomp($lastVersion);
                $lastCheck = $now;

                Info( "Got version: '".$lastVersion."'\n" );

                my $lv_sql = "update Config set Value = ? where Name = 'ZM_DYN_LAST_VERSION'";
                my $lv_sth = $dbh->prepare_cached( $lv_sql ) or die( "Can't prepare '$lv_sql': ".$dbh->errstr() );
                my $lv_res = $lv_sth->execute( $lastVersion ) or die( "Can't execute: ".$lv_sth->errstr() );

                my $lc_sql = "update Config set Value = ? where Name = 'ZM_DYN_LAST_CHECK'";
                my $lc_sth = $dbh->prepare_cached( $lc_sql ) or die( "Can't prepare '$lc_sql': ".$dbh->errstr() );
                my $lc_res = $lc_sth->execute( $lastCheck ) or die( "Can't execute: ".$lc_sth->errstr() );
            }
            else
            {
                Error( "Error check failed: '".$res->status_line()."'\n" );
            }
            zmDbDisconnect();
        }
        sleep( 3600 );
    }
    print( "Update agent exiting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() )."\n" );
}
if ( $rename )
{
    require File::Find;

    chdir( EVENT_PATH );

    sub renameImage
    {
        my $file = $_;

        # Ignore directories
        if ( -d $file )
        {
            print( "Checking directory '$file'\n" );
            return;
        }
        if ( $file !~ /(capture|analyse)-(\d+)(\.jpg)/ )
        {
            return;
        }
        my $newFile = "$2-$1$3";

        print( "Renaming '$file' to '$newFile'\n" );
        rename( $file, $newFile ) or warn( "Can't rename '$file' to '$newFile'" );
    }

    File::Find::find( \&renameImage, '.' );
}
if ( $zoneFix )
{
    require DBI;

    my $dbh = zmDbConnect();

    my $sql = "select Z.*, M.Width as MonitorWidth, M.Height as MonitorHeight from Zones as Z inner join Monitors as M on Z.MonitorId = M.Id where Z.Units = 'Percent'";
    my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
    my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
    my @zones;
    while( my $zone = $sth->fetchrow_hashref() )
    {
        push( @zones, $zone );
    }
    $sth->finish();

    foreach my $zone ( @zones )
    {
        my $zone_width = (($zone->{HiX}*$zone->{MonitorWidth})-($zone->{LoX}*$zone->{MonitorWidth}))/100;
        my $zone_height = (($zone->{HiY}*$zone->{MonitorHeight})-($zone->{LoY}*$zone->{MonitorHeight}))/100;
        my $zone_area = $zone_width * $zone_height;
        my $monitor_area = $zone->{MonitorWidth} * $zone->{MonitorHeight};
        my $sql = "update Zones set MinAlarmPixels = ?, MaxAlarmPixels = ?, MinFilterPixels = ?, MaxFilterPixels = ?, MinBlobPixels = ?, MaxBlobPixels = ? where Id = ?";
        my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute(
            ($zone->{MinAlarmPixels}*$monitor_area)/$zone_area,
            ($zone->{MaxAlarmPixels}*$monitor_area)/$zone_area,
            ($zone->{MinFilterPixels}*$monitor_area)/$zone_area,
            ($zone->{MaxFilterPixels}*$monitor_area)/$zone_area,
            ($zone->{MinBlobPixels}*$monitor_area)/$zone_area,
            ($zone->{MaxBlobPixels}*$monitor_area)/$zone_area,
            $zone->{Id}
        ) or die( "Can't execute: ".$sth->errstr() );
    }
}
if ( $migrateEvents )
{
    my $webUid = (getpwnam( ZM_WEB_USER ))[2];
    my $webGid = (getgrnam( ZM_WEB_USER ))[2];

    if ( !(($> == 0) || ($> == $webUid)) )
    {
        print( "Error, migrating events can only be done as user root or ".ZM_WEB_USER.".\n" );
        exit( -1 );
    }

    # Run as web user/group
    $( = $webGid;
    $) = $webGid;
    $< = $webUid;
    $> = $webUid;

    print( "\nAbout to convert saved events to deep storage, please ensure that ZoneMinder is fully stopped before proceeding.\nThis process is not easily reversible. Are you sure you wish to proceed?\n\nPress 'y' to continue or 'n' to abort : " );
    my $response = <STDIN>;
    chomp( $response );
    while ( $response !~ /^[yYnN]$/ )
    {
        print( "Please press 'y' to continue or 'n' to abort only : " );
        $response = <STDIN>;
        chomp( $response );
    }

    if ( $response =~ /^[yY]$/ )
    {
        print( "Converting all events to deep storage.\n" );

        chdir( ZM_PATH_WEB );
        my $dbh = zmDbConnect();
        my $sql = "select *, unix_timestamp(StartTime) as UnixStartTime from Events";
        my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute();
        if ( !$res )
        {
            Fatal( "Can't fetch Events: ".$sth->errstr() );
        }

        while( my $event = $sth->fetchrow_hashref() )
        {
            my $oldEventPath = ZM_DIR_EVENTS.'/'.$event->{MonitorId}.'/'.$event->{Id};

            if ( !-d $oldEventPath )
            {
                print( "Warning, can't find old event path '$oldEventPath', already converted?\n" );
                next;
            }

            print( "Converting event ".$event->{Id}."\n" );
            my $newDatePath = ZM_DIR_EVENTS.'/'.$event->{MonitorId}.'/'.strftime( "%y/%m/%d", localtime($event->{UnixStartTime}) );
            my $newTimePath = strftime( "%H/%M/%S", localtime($event->{UnixStartTime}) );
            my $newEventPath = $newDatePath.'/'.$newTimePath;
            ( my $truncEventPath = $newEventPath ) =~ s|/\d+$||;
            makePath( ZM_PATH_WEB, $truncEventPath );
            my $idLink = $newDatePath.'/.'.$event->{Id};
            symlink( $newTimePath, $idLink ) or die( "Can't symlink $newTimePath -> $idLink: $!" );
            rename( $oldEventPath, $newEventPath ) or die( "Can't move $oldEventPath -> $newEventPath: $!" );
        }

        print( "Updating configuration.\n" );
        $sql = "update Config set Value = ? where Name = 'ZM_USE_DEEP_STORAGE'";
        $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        $res = $sth->execute( 1 ) or die( "Can't execute: ".$sth->errstr() );

        print( "All events converted.\n\n" );
    }
    else
    {
        print( "Aborting event conversion.\n\n" );
    }
}
if ( $freshen )
{
    print( "\nFreshening configuration in database\n" );
    loadConfigFromDB();
    saveConfigToDB();
}
if ( $version )
{
    my ( $detaint_version ) = $version =~ /^([\w.]+)$/;
    $version = $detaint_version;

    if ( ZM_VERSION eq $version )
    {
        print( "\nDatabase already at version $version, update aborted.\n\n" );
        exit( -1 );
    }

    print( "\nInitiating database upgrade to version ".ZM_VERSION." from version $version\n" );
    if ( $interactive )
    {
        if ( ZM_DYN_DB_VERSION && ZM_DYN_DB_VERSION ne $version )
        {
            print( "\nWARNING - You have specified an upgrade from version $version but the database version found is ".ZM_DYN_DB_VERSION.". Is this correct?\nPress enter to continue or ctrl-C to abort : " );
            my $response = <STDIN>;
        }

        print( "\nPlease ensure that ZoneMinder is stopped on your system prior to upgrading the database.\nPress enter to continue or ctrl-C to stop : " );
        my $response = <STDIN>;

        print( "\nDo you wish to take a backup of your database prior to upgrading?\nThis may result in a large file in /tmp/zm if you have a lot of events.\nPress 'y' for a backup or 'n' to continue : " );
        $response = <STDIN>;
        chomp( $response );
        while ( $response !~ /^[yYnN]$/ )
        {
            print( "Please press 'y' for a backup or 'n' to continue only : " );
            $response = <STDIN>;
            chomp( $response );
        }

        if ( $response =~ /^[yY]$/ )
        {
            my ( $host, $port ) = ( ZM_DB_HOST =~ /^([^:]+)(?::(.+))?$/ );
            my $command = "mysqldump -h".$host;
            $command .= " -P".$port if defined($port);
            if ( $dbUser )
            {
                $command .= " -u".$dbUser;
                if ( $dbPass )
                {
                    $command .= " -p".$dbPass;
                }
            }
            my $backup = "/tmp/zm/".ZM_DB_NAME."-".$version.".dump";
            $command .= " --add-drop-table --databases ".ZM_DB_NAME." > ".$backup;
            print( "Creating backup to $backup. This may take several minutes.\n" );
            print( "Executing '$command'\n" ) if ( logDebugging() );
            my $output = qx($command);
            my $status = $? >> 8;
            if ( $status || logDebugging() )
            {
                    chomp( $output );
                    print( "Output: $output\n" );
            }
            if ( $status )
            {
                die( "Command '$command' exited with status: $status\n" );
            }
            else
            {
                print( "Database successfully backed up to $backup, proceeding to upgrade.\n" );
            }
        }
        elsif ( $response !~ /^[nN]$/ )
        {
            die( "Unexpected response '$response'" );
        }
    }
    sub patchDB
    {
        my $dbh = shift;
        my $version = shift;

        my ( $host, $port ) = ( ZM_DB_HOST =~ /^([^:]+)(?::(.+))?$/ );
        my $command = "mysql -h".$host;
        $command .= " -P".$port if defined($port);
        if ( $dbUser )
        {
            $command .= " -u".$dbUser;
            if ( $dbPass )
            {
                $command .= " -p".$dbPass;
            }
        }
        $command .= " ".ZM_DB_NAME." < ";
        if ( $updateDir )
        {
            $command -= $updateDir;
        }
        else
        {
            $command .= ZM_PATH_BUILD."/db";
        }
        $command .= "/zm_update-".$version.".sql";

        print( "Executing '$command'\n" ) if ( logDebugging() );
        my $output = qx($command);
        my $status = $? >> 8;
        if ( $status || logDebugging() )
        {
                chomp( $output );
                print( "Output: $output\n" );
        }
        if ( $status )
        {
            die( "Command '$command' exited with status: $status\n" );
        }
        else
        {
            print( "\nDatabase successfully upgraded from version $version.\n" );
            my $sql = "update Config set Value = ? where Name = 'ZM_DYN_DB_VERSION'";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute( $version ) or die( "Can't execute: ".$sth->errstr() );
        }
    }

    print( "\nUpgrading database to version ".ZM_VERSION."\n" );

    # Update config first of all
    loadConfigFromDB();
    saveConfigToDB();

    my $dbh = zmDbConnect();

    my $cascade = undef;
    if ( $cascade || $version eq "1.19.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.19.0" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.19.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.19.1");
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.19.2" )
    {
        # Patch the database
        patchDB( $dbh, "1.19.2" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.19.3" )
    {
        # Patch the database
        patchDB( $dbh, "1.19.3" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.19.4" )
    {
        require DBI;

        # Rename the event directories and create a new symlink for the names
        chdir( EVENT_PATH );

        my $sql = "select * from Monitors order by Id";
        my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
        while( my $monitor = $sth->fetchrow_hashref() )
        {
            if ( -d $monitor->{Name} )
            {
                rename( $monitor->{Name}, $monitor->{Id} ) or warn( "Can't rename existing monitor directory '$monitor->{Name}' to '$monitor->{Id}': $!" );
                symlink( $monitor->{Id}, $monitor->{Name} ) or warn( "Can't symlink monitor directory '$monitor->{Id}' to '$monitor->{Name}': $!" );
            }
        }
        $sth->finish();
        
        # Patch the database
        patchDB( $dbh, "1.19.4" );

        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.19.5" )
    {
        print( "\nThis version now only uses one database user.\nPlease ensure you have run zmconfig.pl and re-entered your database username and password prior to upgrading, or the upgrade will fail.\nPress enter to continue or ctrl-C to stop : " );
        # Patch the database
        my $dummy = <STDIN>;
        patchDB( $dbh, "1.19.5" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.20.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.20.0" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.20.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.20.1" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.21.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.21.0" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.21.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.21.1" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.21.2" )
    {
        # Patch the database
        patchDB( $dbh, "1.21.2" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.21.3" )
    {
        # Patch the database
        patchDB( $dbh, "1.21.3" );

        # Add appropriate widths and heights to events
        {
        print( "Updating events. This may take a few minutes. Please wait.\n" );
        my $sql = "select * from Monitors order by Id";
        my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
        while( my $monitor = $sth->fetchrow_hashref() )
        {
            my $sql = "update Events set Width = ?, Height = ? where MonitorId = ?";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute( $monitor->{Width}, $monitor->{Height}, $monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
        }
        $sth->finish();
        }

        # Add sequence numbers
        {
            print( "Updating monitor sequences. Please wait.\n" );
            my $sql = "select * from Monitors order by Id";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my $sequence = 1;
            while( my $monitor = $sth->fetchrow_hashref() )
            {
                my $sql = "update Monitors set Sequence = ? where Id = ?";
                my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute( $sequence++, $monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
            }
            $sth->finish();
        }

        # Update saved filters
        {
            print( "Updating saved filters. Please wait.\n" );
            my $sql = "select * from Filters";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @filters;
            while( my $filter = $sth->fetchrow_hashref() )
            {
                push( @filters, $filter );
            }
            $sth->finish();
            $sql = "update Filters set Query = ? where Name = ?";
            $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            foreach my $filter ( @filters )
            {
                if ( $filter->{Query} =~ /op\d=&/ )
                {
                    ( my $newQuery = $filter->{Query} ) =~ s/(op\d=)&/$1=&/g;
                    $res = $sth->execute( $newQuery, $filter->{Name} ) or die( "Can't execute: ".$sth->errstr() );
                }
            }
        }

        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.21.4" )
    {
        # Patch the database
        patchDB( $dbh, "1.21.4" );

        # Convert zones to new format
        {
            print( "Updating zones. Please wait.\n" );

            # Get the existing zones from the DB
            my $sql = "select Z.*,M.Width,M.Height from Zones as Z inner join Monitors as M on (Z.MonitorId = M.Id)";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @zones;
            while( my $zone = $sth->fetchrow_hashref() )
            {
                push( @zones, $zone );
            }
            $sth->finish();

            no strict 'refs';
            foreach my $zone ( @zones )
            {
                # Create the coordinate strings
                if ( $zone->{Units} eq "Pixels" )
                {
                    my $sql = "update Zones set NumCoords = 4, Coords = concat( LoX,',',LoY,' ',HiX,',',LoY,' ',HiX,',',HiY,' ',LoX,',',HiY ), Area = round( ((HiX-LoX)+1)*((HiY-LoY)+1) ) where Id = ?"; 
                    my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                    my $res = $sth->execute( $zone->{Id} ) or die( "Can't execute: ".$sth->errstr() );
                }
                else
                {
                    my $loX = ($zone->{LoX} * ($zone->{Width}-1) ) / 100;
                    my $hiX = ($zone->{HiX} * ($zone->{Width}-1) ) / 100;
                    my $loY = ($zone->{LoY} * ($zone->{Height}-1) ) / 100;
                    my $hiY = ($zone->{HiY} * ($zone->{Height}-1) ) / 100;
                    my $area = (($hiX-$loX)+1)*(($hiY-$loY)+1);
                    my $sql = "update Zones set NumCoords = 4, Coords = concat( round(?),',',round(?),' ',round(?),',',round(?),' ',round(?),',',round(?),' ',round(?),',',round(?) ), Area = round(?), MinAlarmPixels = round(?), MaxAlarmPixels = round(?), MinFilterPixels = round(?), MaxFilterPixels = round(?), MinBlobPixels = round(?), MaxBlobPixels = round(?) where Id = ?"; 
                    my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                    my $res = $sth->execute( $loX, $loY, $hiX, $loY, $hiX, $hiY, $loX, $hiY, $area, ($zone->{MinAlarmPixels}*$area)/100, ($zone->{MaxAlarmPixels}*$area)/100, ($zone->{MinFilterPixels}*$area)/100, ($zone->{MaxFilterPixels}*$area)/100, ($zone->{MinBlobPixels}*$area)/100, ($zone->{MaxBlobPixels}*$area)/100, $zone->{Id} ) or die( "Can't execute: ".$sth->errstr() );
                }
            }
        }
        # Convert run states to new format
        {
            print( "Updating run states. Please wait.\n" );

            # Get the existing zones from the DB
            my $sql = "select * from States";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @states;
            while( my $state = $sth->fetchrow_hashref() )
            {
                push( @states, $state );
            }
            $sth->finish();

            foreach my $state ( @states )
            {
                my @new_defns;
                foreach my $defn ( split( /,/, $state->{Definition} ) )
                {
                    push( @new_defns, $defn.":1" );
                }
                my $sql = "update States set Definition = ? where Name = ?";
                my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute( join( ',', @new_defns ), $state->{Name} ) or die( "Can't execute: ".$sth->errstr() );
            }
        }

        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.22.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.22.0" );

        # Check for maximum FPS setting and update alarm max fps settings
        {
            print( "Updating monitors. Please wait.\n" );
            if ( defined(&ZM_NO_MAX_FPS_ON_ALARM) && &ZM_NO_MAX_FPS_ON_ALARM )
            {
                # Update the individual monitor settings to match the previous global one
                my $sql = "update Monitors set AlarmMaxFPS = NULL";
                my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            }
            else
            {
                # Update the individual monitor settings to match the previous global one
                my $sql = "update Monitors set AlarmMaxFPS = MaxFPS";
                my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            }
        }
        {
            print( "Updating mail configuration. Please wait.\n" );
            my ( $sql, $sth, $res );
            if ( defined(&ZM_EMAIL_TEXT) && &ZM_EMAIL_TEXT )
            {
                my ( $email_subject, $email_body ) = ZM_EMAIL_TEXT =~ /subject\s*=\s*"([^\n]*)".*body\s*=\s*"(.*)"?$/ms;
                $sql = "replace into Config set Id = 0, Name = 'ZM_EMAIL_SUBJECT', Value = '".$email_subject."', Type = 'string', DefaultValue = 'ZoneMinder: Alarm - %MN%-%EI% (%ESM% - %ESA% %EFA%)', Hint = 'string', Pattern = '(?-xism:^(.+)\$)', Format = ' \$1 ', Prompt = 'The subject of the email used to send matching event details', Help = 'This option is used to define the subject of the email that is sent for any events that match the appropriate filters.', Category = 'mail', Readonly = '0', Requires = 'ZM_OPT_EMAIL=1'";
                $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
                $sql = "replace into Config set Id = 0, Name = 'ZM_EMAIL_BODY', Value = '".$email_body."', Hint = 'free text', Pattern = '(?-xism:^(.+)\$)', Format = ' \$1 ', Prompt = 'The body of the email used to send matching event details', Help = 'This option is used to define the content of the email that is sent for any events that match the appropriate filters.', Category = 'mail', Readonly = '0', Requires = 'ZM_OPT_EMAIL=1'";
                $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            }
            if ( defined(&ZM_MESSAGE_TEXT) && &ZM_MESSAGE_TEXT )
            {
                my ( $message_subject, $message_body ) = ZM_MESSAGE_TEXT =~ /subject\s*=\s*"([^\n]*)".*body\s*=\s*"(.*)"?$/ms;
                $sql = "replace into Config set Id = 0, Name = 'ZM_MESSAGE_SUBJECT', Value = '".$message_subject."', Type = 'string', DefaultValue = 'ZoneMinder: Alarm - %MN%-%EI%', Hint = 'string', Pattern = '(?-xism:^(.+)\$)', Format = ' \$1 ', Prompt = 'The subject of the message used to send matching event details', Help = 'This option is used to define the subject of the message that is sent for any events that match the appropriate filters.', Category = 'mail', Readonly = '0', Requires = 'ZM_OPT_MESSAGE=1'";
                $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
                $sql = "replace into Config set Id = 0, Name = 'ZM_MESSAGE_BODY', Value = '".$message_body."', Type = 'text', DefaultValue = 'ZM alarm detected - %ED% secs, %EF%/%EFA% frames, t%EST%/m%ESM%/a%ESA% score.', Hint = 'free text', Pattern = '(?-xism:^(.+)\$)', Format = ' \$1 ', Prompt = 'The body of the message used to send matching event details', Help = 'This option is used to define the content of the message that is sent for any events that match the appropriate filters.', Category = 'mail', Readonly = '0', Requires = 'ZM_OPT_MESSAGE=1'";
                $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            }
        }
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.22.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.22.1" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.22.2" )
    {
        # Patch the database
        patchDB( $dbh, "1.22.2" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.22.3" )
    {
        # Patch the database
        patchDB( $dbh, "1.22.3" );

        # Convert timestamp strings to new format
        {
            my $sql = "select * from Monitors";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @db_monitors;
            while( my $db_monitor = $sth->fetchrow_hashref() )
            {
                push( @db_monitors, $db_monitor );
            }
            $sth->finish();
            foreach my $db_monitor ( @db_monitors )
            {
                if ( $db_monitor->{LabelFormat} =~ /\%\%s/ )
                {
                    $db_monitor->{LabelFormat} =~ s/\%\%s/%N/;
                    $db_monitor->{LabelFormat} =~ s/\%\%s/%Q/;

                    my $sql = "update Monitors set LabelFormat = ? where Id = ?";
                    my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                    my $res = $sth->execute( $db_monitor->{LabelFormat}, $db_monitor->{Id} ) or die( "Can't execute: ".$sth->errstr() );
                }
            }
        }

        # Convert filters to new format
        {
            my $sql = "select * from Filters";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @dbFilters;
            while( my $dbFilter = $sth->fetchrow_hashref() )
            {
                push( @dbFilters, $dbFilter );
            }
            $sth->finish();
            foreach my $dbFilter ( @dbFilters )
            {
                my %filter_terms;
                foreach my $filter_parm ( split( /&/, $dbFilter->{Query} ) )
                {
                    my( $key, $value ) = split( /=/, $filter_parm, 2 );
                    if ( $key )
                    {
                        $filter_terms{$key} = $value;
                    }
                }
                my $filter = { 'terms' => [] };
                for ( my $i = 1; $i <= $filter_terms{trms}; $i++ )
                {
                    my $term = {};
                    my $conjunction_name = "cnj$i";
                    my $obracket_name = "obr$i";
                    my $cbracket_name = "cbr$i";
                    my $attr_name = "attr$i";
                    my $op_name = "op$i";
                    my $value_name = "val$i";

                    $term->{cnj} = $filter_terms{$conjunction_name} if ( $filter_terms{$conjunction_name} );
                    $term->{obr} = $filter_terms{$obracket_name} if ( $filter_terms{$obracket_name} );
                    $term->{attr} = $filter_terms{$attr_name} if ( $filter_terms{$attr_name} );
                    $term->{val} = $filter_terms{$value_name} if ( defined($filter_terms{$value_name}) );
                    $term->{op} = $filter_terms{$op_name} if ( $filter_terms{$op_name} );
                    $term->{cbr} = $filter_terms{$cbracket_name} if ( $filter_terms{$cbracket_name} );
                    push( @{$filter->{terms}}, $term );
                }
                $filter->{sort_field} = $filter_terms{sort_field} if ( $filter_terms{sort_field} );
                $filter->{sort_asc} = $filter_terms{sort_asc} if ( $filter_terms{sort_asc} );
                $filter->{limit} = $filter_terms{limit} if ( $filter_terms{limit} );

                my $newQuery = 'a:'.int(keys(%$filter)).':{s:5:"terms";a:'.int(@{$filter->{terms}}).':{';
                my $i = 0;
                foreach my $term ( @{$filter->{terms}} )
                {
                    $newQuery .= 'i:'.$i.';a:'.int(keys(%$term)).':{';
                    while ( my ( $key, $val ) = each( %$term ) )
                    {
                        $newQuery .= 's:'.length($key).':"'.$key.'";';
                        $newQuery .= 's:'.length($val).':"'.$val.'";';
                    }
                    $newQuery .= '}';
                    $i++;
                }
                $newQuery .= '}';
                foreach my $field ( "sort_field", "sort_asc", "limit" )
                {
                    if ( defined($filter->{$field}) )
                    {
                        $newQuery .= 's:'.length($field).':"'.$field.'";';
                        $newQuery .= 's:'.length($filter->{$field}).':"'.$filter->{$field}.'";';
                    }
                }
                $newQuery .= '}';

                my $sql = "update Filters set Query = ? where Name = ?";
                my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                my $res = $sth->execute( $newQuery, $dbFilter->{Name} ) or die( "Can't execute: ".$sth->errstr() );
            }
        }

        # Update the stream quality setting to the old image quality ones
        {
            my $dbh = zmDbConnect();

            my $sql = "update Config set Value = ? where Name = 'ZM_JPEG_STREAM_QUALITY'";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute( ZM_JPEG_IMAGE_QUALITY ) or die( "Can't execute: ".$sth->errstr() );
        }
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.23.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.23.0" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.23.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.23.1" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.23.2" )
    {
        # Patch the database
        patchDB( $dbh, "1.23.2" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.23.3" )
    {
        # Patch the database
        patchDB( $dbh, "1.23.3" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.24.0" )
    {
        # Patch the database
        patchDB( $dbh, "1.24.0" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.24.1" )
    {
        # Patch the database
        patchDB( $dbh, "1.24.1" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.24.2" )
    {
        # Patch the database
        patchDB( $dbh, "1.24.2" );
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.24.3" )
    {
        my $result = eval
        {
            require PHP::Serialization;
            PHP::Serialization->import();
        };
        die( "Unable to perform upgrade from 1.24.3, PHP::Serialization module not found" ) if ( $result );

        # Patch the database
        patchDB( $dbh, "1.24.3" );

        # Convert filters to JSON from PHP format serialisation
        {
            print( "\nConverting filters from PHP to JSON format\n" );
            my $sql = "select * from Filters";
            my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
            my $res = $sth->execute() or die( "Can't execute: ".$sth->errstr() );
            my @dbFilters;
            while( my $dbFilter = $sth->fetchrow_hashref() )
            {
                push( @dbFilters, $dbFilter );
            }
            $sth->finish();
            foreach my $dbFilter ( @dbFilters )
            {
                print( "  ".$dbFilter->{Name} );
                eval {
                    my $phpQuery = $dbFilter->{Query};
                    my $query = PHP::Serialization::unserialize( $phpQuery );
                    my $jsonQuery = jsonEncode( $query );
                    my $sql = "update Filters set Query = ? where Name = ?";
                    my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
                    my $res = $sth->execute( $jsonQuery, $dbFilter->{Name} ) or die( "Can't execute: ".$sth->errstr() );
                };
                if ( $@ )
                {
                    print( " - failed, please check or report. Query is '".$dbFilter->{Query}."'\n" );
                    print( $@ );
                }
                else
                {
                    print( " - complete\n" );
                }
            }
            print( "Conversion complete\n" );
        }
        $cascade = !undef;
    }
    if ( $cascade || $version eq "1.24.4" )
    {
        # Patch the database
        patchDB( $dbh, "1.24.4" );

        # Copy the FTP specific values to the new general config
        my $fetchSql = "select * from Config where Name like 'ZM_UPLOAD_FTP_%'";
        my $fetchSth = $dbh->prepare_cached( $fetchSql ) or die( "Can't prepare '$fetchSql': ".$dbh->errstr() );
        my $updateSql = "update Config set Value = ? where Name = ?";
        my $updateSth = $dbh->prepare_cached( $updateSql ) or die( "Can't prepare '$updateSql': ".$dbh->errstr() );
        my $fetchRes = $fetchSth->execute() or die( "Can't execute: ".$fetchSth->errstr() );
        while( my $config = $fetchSth->fetchrow_hashref() )
        {
            ( my $name = $config->{Name} ) =~ s/_FTP_/_/;
            my $updateRes = $updateSth->execute( $config->{Value}, $name ) or die( "Can't execute: ".$updateSth->errstr() );
        }
        $cascade = !undef;
    }
    if ( $cascade )
    {
        my $installed_version = ZM_VERSION;
        my $sql = "update Config set Value = ? where Name = ?";
        my $sth = $dbh->prepare_cached( $sql ) or die( "Can't prepare '$sql': ".$dbh->errstr() );
        my $res = $sth->execute( "$installed_version", "ZM_DYN_DB_VERSION" ) or die( "Can't execute: ".$sth->errstr() );
        $res = $sth->execute( "$installed_version", "ZM_DYN_CURR_VERSION" ) or die( "Can't execute: ".$sth->errstr() );
        $dbh->disconnect();
    }
    else
    {
        $dbh->disconnect();
        die( "Can't find upgrade from version '$version'" );
    }
    print( "\nDatabase upgrade to version ".ZM_VERSION." successful.\n\n" );
}
exit( 0 );
