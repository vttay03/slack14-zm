#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Package Control Script, $Date: 2011-08-26 08:51:36 +0100 (Fri, 26 Aug 2011) $, $Revision: 3505 $
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
# This script is used to start and stop the ZoneMinder package primarily to
# allow command line control for automatic restart on reboot (see zm script)
#
use strict;
use bytes;

# ==========================================================================
#
# Don't change anything below here
#
# ==========================================================================

# Include from system perl paths only
use ZoneMinder;
use DBI;
use POSIX;
use Time::HiRes qw/gettimeofday/;

# Detaint our environment
$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

logInit();

my $command = $ARGV[0];

my $state;

my $dbh = zmDbConnect();

if ( !$command || $command !~ /^(?:start|stop|restart|status|logrot)$/ )
{
	if ( $command )
	{
		# Check to see if it's a valid run state
		my $sql = "select * from States where Name = '$command'";
		my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or Fatal( "Can't execute: ".$sth->errstr() );
		if ( $state = $sth->fetchrow_hashref() )
		{
			$state->{Name} = $command;
			$state->{Definitions} = [];
			foreach( split( /,/, $state->{Definition} ) )
			{
				my ( $id, $function, $enabled ) = split( /:/, $_ );
				push( @{$state->{Definitions}}, { Id=>$id, Function=>$function, Enabled=>$enabled } );
			}
			$command = 'state';
		}
		else
		{
			$command = undef;
		}
	}
	if ( !$command )
	{
		print( "Usage: zmpkg.pl <start|stop|restart|status|logrot|'state'>\n" );
		exit( -1 );
	}
}

# Move to the right place
chdir( ZM_PATH_WEB ) or Fatal( "Can't chdir to '".ZM_PATH_WEB."': $!" );

my $dbg_id = "";

Info( "Command: $command\n" );

my $retval = 0;

if ( $command eq "state" )
{
	Info( "Updating DB: $state->{Name}\n" );
	my $sql = "select * from Monitors order by Id asc";
	my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
	my $res = $sth->execute() or Fatal( "Can't execute: ".$sth->errstr() );
	while( my $monitor = $sth->fetchrow_hashref() )
	{
		foreach my $definition ( @{$state->{Definitions}} )
		{
			if ( $monitor->{Id} =~ /^$definition->{Id}$/ )
			{
				$monitor->{NewFunction} = $definition->{Function};
				$monitor->{NewEnabled} = $definition->{Enabled};
			}
		}
		#next if ( !$monitor->{NewFunction} );
		$monitor->{NewFunction} = 'None' if ( !$monitor->{NewFunction} );
		$monitor->{NewEnabled} = 0 if ( !$monitor->{NewEnabled} );
		if ( $monitor->{Function} ne $monitor->{NewFunction} || $monitor->{Enabled} ne $monitor->{NewEnabled} )
		{
			my $sql = "update Monitors set Function = ?, Enabled = ? where Id = ?";
			my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
			my $res = $sth->execute( $monitor->{NewFunction}, $monitor->{NewEnabled}, $monitor->{Id} ) or Fatal( "Can't execute: ".$sth->errstr() );
		}
	}
	$sth->finish();

	$command = "restart";
}

if ( $command =~ /^(?:stop|restart)$/ )
{
	my $status = runCommand( "zmdc.pl check" );

	if ( $status eq "running" )
	{
		runCommand( "zmdc.pl shutdown" );
		zmMemTidy();
	}
	else
	{
		$retval = 1;
	}
}

runCommand( "zmupdate.pl -f" );

if ( $command =~ /^(?:start|restart)$/ )
{
	my $status = runCommand( "zmdc.pl check" );

	if ( $status eq "stopped" )
	{
        if ( ZM_DYN_DB_VERSION && ZM_DYN_DB_VERSION ne ZM_VERSION )
        {
            Fatal( "Version mismatch, system is version ".ZM_VERSION.", database is ".ZM_DYN_DB_VERSION.", please run zmupdate.pl to update." );
            exit( -1 );
        }

        # Recreate the temporary directory if it's been wiped
        if ( !-e "/tmp/zm" )
        {
            Debug( "Recreating temporary directory '/tmp/zm'" );
            mkdir( "/tmp/zm", 0700 ) or Fatal( "Can't create missing temporary directory '/tmp/zm': $!" );
            my ( $runName ) = getpwuid( $> );
            if ( $runName ne ZM_WEB_USER )
            {
                # Not running as web user, so should be root in whch case chown the temporary directory
                my ( $webName, $webPass, $webUid, $webGid ) = getpwnam( ZM_WEB_USER ) or Fatal( "Can't get user details for web user '".ZM_WEB_USER."': $!" );
                chown( $webUid, $webGid, "/tmp/zm" ) or Fatal( "Can't change ownership of temporary directory '/tmp/zm' to '".ZM_WEB_USER.":".ZM_WEB_GROUP."': $!" );
            }
        }
		zmMemTidy();
		runCommand( "zmfix" );
		runCommand( "zmdc.pl startup" );

		my $sql = "select * from Monitors";
		my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
		my $res = $sth->execute() or Fatal( "Can't execute: ".$sth->errstr() );
		while( my $monitor = $sth->fetchrow_hashref() )
		{
			if ( $monitor->{Function} ne 'None' )
			{
				if ( $monitor->{Type} eq 'Local' )
				{
					runCommand( "zmdc.pl start zmc -d $monitor->{Device}" );
				}
				else
				{
					runCommand( "zmdc.pl start zmc -m $monitor->{Id}" );
				}
				if ( $monitor->{Function} ne 'Monitor' )
				{
					if ( ZM_OPT_FRAME_SERVER )
					{
						runCommand( "zmdc.pl start zmf -m $monitor->{Id}" );
					}
					runCommand( "zmdc.pl start zma -m $monitor->{Id}" );
				}
				if ( ZM_OPT_CONTROL )
				{
					if ( $monitor->{Function} eq 'Modect' || $monitor->{Function} eq 'Mocord' )
					{
						if ( $monitor->{Controllable} && $monitor->{TrackMotion} )
						{
							runCommand( "zmdc.pl start zmtrack.pl -m $monitor->{Id}" );
						}
					}
				}
			}
		}
		$sth->finish();

		# This is now started unconditionally
		runCommand( "zmdc.pl start zmfilter.pl" );
		if ( ZM_RUN_AUDIT )
		{
			runCommand( "zmdc.pl start zmaudit.pl -c" );
		}
		if ( ZM_OPT_TRIGGERS )
		{
			runCommand( "zmdc.pl start zmtrigger.pl" );
		}
		if ( ZM_OPT_X10 )
		{
			runCommand( "zmdc.pl start zmx10.pl -c start" );
		}
		runCommand( "zmdc.pl start zmwatch.pl" );
		if ( ZM_CHECK_FOR_UPDATES )
		{
			runCommand( "zmdc.pl start zmupdate.pl -c" );
		}
	}
	else
	{
		$retval = 1;
	}
}

if ( $command eq "status" )
{
	my $status = runCommand( "zmdc.pl check" );

	print( STDOUT $status."\n" );
}

if ( $command eq "logrot" )
{
	runCommand( "zmdc.pl logrot" );
}

exit( $retval );
