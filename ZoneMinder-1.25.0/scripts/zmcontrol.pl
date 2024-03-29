#!/usr/bin/perl -wT
#
# ==========================================================================
#
# ZoneMinder Control Script, $Date: 2011-06-24 10:04:32 +0100 (Fri, 24 Jun 2011) $, $Revision: 3465 $
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

# Include from system perl paths only
use ZoneMinder;
use Getopt::Long;
use POSIX qw/strftime EPIPE/;
use Socket;
use Data::Dumper;
use Module::Load;

use constant MAX_CONNECT_DELAY => 10;
use constant MAX_COMMAND_WAIT => 1800;

$| = 1;

$ENV{PATH}  = '/bin:/usr/bin';
$ENV{SHELL} = '/bin/sh' if exists $ENV{SHELL};
delete @ENV{qw(IFS CDPATH ENV BASH_ENV)};

sub Usage
{
    print( "
Usage: zmcontrol.pl --id <monitor_id> --command=<command> <various options>
");
    exit( -1 );
}

logInit();

my $arg_string = join( " ", @ARGV );

my $id;
my %options;

if ( !GetOptions(
    'id=i'=>\$id,
    'command=s'=>\$options{command},
    'xcoord=i'=>\$options{xcoord},
    'ycoord=i'=>\$options{ycoord},
    'speed=i'=>\$options{speed},
    'step=i'=>\$options{step},
    'panspeed=i'=>\$options{panspeed},
    'tiltspeed=i'=>\$options{tiltspeed},
    'panstep=i'=>\$options{panstep},
    'tiltstep=i'=>\$options{tiltstep},
    'preset=i'=>\$options{preset},
    'autostop'=>\$options{autostop},
    )
)
{
    Usage();
}

if ( !$id || !$options{command} )
{
    print( STDERR "Please give a valid monitor id and command\n" );
    Usage();
}

( $id ) = $id =~ /^(\w+)$/;

Debug( $arg_string );

my $sock_file = ZM_PATH_SOCKS.'/zmcontrol-'.$id.'.sock';

socket( CLIENT, PF_UNIX, SOCK_STREAM, 0 ) or Fatal( "Can't open socket: $!" );

my $saddr = sockaddr_un( $sock_file );
my $server_up = connect( CLIENT, $saddr );
if ( !$server_up )
{
    # The server isn't there 
    my $monitor = zmDbGetMonitorAndControl( $id );
    if ( !$monitor )
    {
        Fatal( "Unable to load control data for monitor $id" );
    }
    my $protocol = $monitor->{Protocol};

    if ( -x $protocol )
    {
        # Protocol is actually a script!
        # Holdover from previous versions
        my $command .= $protocol.' '.$arg_string;
        Debug( $command."\n" );

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
            exit( $status );
        }
        exit( 0 );
    }

    Info( "Starting control server $id/$protocol" );
    close( CLIENT );

    if ( my $cpid = fork() )
    {
        logReinit();

        # Parent process just sleep and fall through
        socket( CLIENT, PF_UNIX, SOCK_STREAM, 0 ) or die( "Can't open socket: $!" );
        my $attempts = 0;
        while (!connect( CLIENT, $saddr ))
        {
            $attempts++;
            Fatal( "Can't connect: $!" ) if ($attempts > MAX_CONNECT_DELAY);
            sleep(1);
        }
    }
    elsif ( defined($cpid) )
    {
        close( STDOUT );
        close( STDERR );

        setpgrp();

        logReinit();

        Info( "Control server $id/$protocol starting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() ) );

        $0 = $0." --id $id";

        load "ZoneMinder::Control::$protocol";

        my $control = "ZoneMinder::Control::$protocol"->new( $id );
        my $control_key = $control->getKey();
        $control->loadMonitor();

        $control->open();

        socket( SERVER, PF_UNIX, SOCK_STREAM, 0 ) or Fatal( "Can't open socket: $!" );
        unlink( $sock_file );
        bind( SERVER, $saddr ) or Fatal( "Can't bind: $!" );
        listen( SERVER, SOMAXCONN ) or Fatal( "Can't listen: $!" );

        my $rin = '';
        vec( $rin, fileno(SERVER), 1 ) = 1;
        my $win = $rin;
        my $ein = $win;
        my $timeout = MAX_COMMAND_WAIT;
        while( 1 )
        {
            my $nfound = select( my $rout = $rin, undef, undef, $timeout );
            if ( $nfound > 0 )
            {
                if ( vec( $rout, fileno(SERVER), 1 ) )
                {
                    my $paddr = accept( CLIENT, SERVER );
                    my $message = <CLIENT>;

                    next if ( !$message );

                    my $params = jsonDecode( $message );
                    #Debug( Dumper( $params ) );

                    my $command = $params->{command};
                    $control->$command( $params );
                    close( CLIENT );
                }
                else
                {
                    Fatal( "Bogus descriptor" );
                }
            }
            elsif ( $nfound < 0 )
            {
                if ( $! == EPIPE )
                {
                    Error( "Can't select: $!" );
                }
                else
                {
                    Fatal( "Can't select: $!" );
                }
            }
            else
            {
                #print( "Select timed out\n" );
                last;
            }
        }
        Info( "Control server $id/$protocol exiting at ".strftime( '%y/%m/%d %H:%M:%S', localtime() ) );
        unlink( $sock_file );
        $control->close();
        exit( 0 );
    }
    else
    {
        Fatal( "Can't fork: $!" );
    }
}

# The server is there, connect to it
#print( "Writing commands\n" );
CLIENT->autoflush();

my $message = jsonEncode( \%options );
print( CLIENT $message );
shutdown( CLIENT, 1 );

exit( 0 );
