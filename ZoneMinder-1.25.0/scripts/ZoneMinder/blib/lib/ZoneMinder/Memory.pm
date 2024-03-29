# ==========================================================================
#
# ZoneMinder Memory Access Module, $Date: 2008-02-25 10:13:13 +0000 (Mon, 25 Feb 2008) $, $Revision: 2323 $
# Copyright (C) 2001-2008  Philip Coombes
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
# This module contains the common definitions and functions used by the rest 
# of the ZoneMinder scripts
#
package ZoneMinder::Memory;

use 5.006;
use strict;
use warnings;

require Exporter;
require ZoneMinder::Base;

our @ISA = qw(Exporter ZoneMinder::Base);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use ZoneMinder ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = (
	'constants' => [ qw(
		STATE_IDLE
		STATE_PREALARM
		STATE_ALARM
		STATE_ALERT
		STATE_TAPE
		ACTION_GET
		ACTION_SET
		ACTION_RELOAD
		ACTION_SUSPEND
		ACTION_RESUME
		TRIGGER_CANCEL
		TRIGGER_ON
		TRIGGER_OFF 
	) ],
	'functions' => [ qw(
		zmMemVerify
		zmMemInvalidate
		zmMemRead
		zmMemWrite
		zmMemTidy
		zmGetMonitorState
		zmGetAlarmLocation
		zmIsAlarmed
		zmInAlarm
		zmHasAlarmed
		zmGetLastEvent
		zmGetLastWriteTime
		zmGetLastReadTime
		zmMonitorEnable
		zmMonitorDisable
		zmMonitorSuspend
		zmMonitorResume
		zmTriggerEventOn
		zmTriggerEventOff
		zmTriggerEventCancel
		zmTriggerShowtext
	) ],
);
push( @{$EXPORT_TAGS{all}}, @{$EXPORT_TAGS{$_}} ) foreach keys %EXPORT_TAGS;

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw();

our $VERSION = $ZoneMinder::Base::VERSION;

# ==========================================================================
#
# Shared Memory Facilities
#
# ==========================================================================

use ZoneMinder::Config qw(:all);
use ZoneMinder::Logger qw(:all);

use constant STATE_IDLE     => 0;
use constant STATE_PREALARM => 1;
use constant STATE_ALARM    => 2;
use constant STATE_ALERT    => 3;
use constant STATE_TAPE     => 4;

use constant ACTION_GET     => 1;
use constant ACTION_SET     => 2;
use constant ACTION_RELOAD  => 4;
use constant ACTION_SUSPEND => 16;
use constant ACTION_RESUME  => 32;

use constant TRIGGER_CANCEL => 0;
use constant TRIGGER_ON     => 1;
use constant TRIGGER_OFF    => 2;

use Storable qw( freeze thaw );

if ( "yes" eq 'yes' ) # 'yes' if memory is mmapped
{
    require ZoneMinder::Memory::Mapped;
    ZoneMinder::Memory::Mapped->import();
}
else
{
    require ZoneMinder::Memory::Shared;
    ZoneMinder::Memory::Shared->import();
}

# Native architecture
our $arch = int(3.2*length(~0));
our $native = $arch/8;
our $mem_seq = 0;

our $mem_data =
{
	"shared_data" => { "type"=>"SharedData", "seq"=>$mem_seq++, "contents"=> {
		"size"             => { "type"=>"int", "seq"=>$mem_seq++ },
		"valid"            => { "type"=>"bool1", "seq"=>$mem_seq++ },
		"active"           => { "type"=>"bool1", "seq"=>$mem_seq++ },
		"signal"           => { "type"=>"bool1", "seq"=>$mem_seq++ },
		"state"            => { "type"=>"enum", "seq"=>$mem_seq++},
		"last_write_index" => { "type"=>"int", "seq"=>$mem_seq++ },
		"last_read_index"  => { "type"=>"int", "seq"=>$mem_seq++ },
		"last_write_time"  => { "type"=>"time_t", "seq"=>$mem_seq++ },
		"last_read_time"   => { "type"=>"time_t", "seq"=>$mem_seq++ },
		"last_event"       => { "type"=>"int", "seq"=>$mem_seq++ },
		"action"           => { "type"=>"enum", "seq"=>$mem_seq++ },
		"brightness"       => { "type"=>"int", "seq"=>$mem_seq++ },
		"hue"              => { "type"=>"int", "seq"=>$mem_seq++ },
		"colour"           => { "type"=>"int", "seq"=>$mem_seq++ },
		"contrast"         => { "type"=>"int", "seq"=>$mem_seq++ },
		"alarm_x"          => { "type"=>"int", "seq"=>$mem_seq++ },
		"alarm_y"          => { "type"=>"int", "seq"=>$mem_seq++ },
		"control_state"    => { "type"=>"uchar[256]", "seq"=>$mem_seq++ },
		}
	},
	"trigger_data" => { "type"=>"TriggerData", "seq"=>$mem_seq++, "contents"=> {
		"size"             => { "type"=>"int", "seq"=>$mem_seq++ },
		"trigger_state"    => { "type"=>"enum", "seq"=>$mem_seq++ },
		"trigger_score"    => { "type"=>"int", "seq"=>$mem_seq++ },
		"trigger_cause"    => { "type"=>"char[32]", "seq"=>$mem_seq++ },
		"trigger_text"     => { "type"=>"char[256]", "seq"=>$mem_seq++ },
		"trigger_showtext" => { "type"=>"char[256]", "seq"=>$mem_seq++ },
		}
	},
	"end" => { "seq"=>$mem_seq++, "size"=> 0 }
};

our $mem_size = 0;
our $mem_verified = {};

sub zmMemInit
{
	my $offset = 0;

	foreach my $section_data ( sort { $a->{seq} <=> $b->{seq} } values( %$mem_data ) )
	{
		$section_data->{offset} = $offset;
		$section_data->{align} = 4;

		if ( $section_data->{align} > 1 )
		{
			my $rem = $offset % $section_data->{align};
			if ( $rem > 0 )
			{
				$offset += ($section_data->{align} - $rem);
			}
		}
		foreach my $member_data ( sort { $a->{seq} <=> $b->{seq} } values( %{$section_data->{contents}} ) )
		{
			if ( $member_data->{type} eq "long" || $member_data->{type} eq "time_t" || $member_data->{type} eq "size_t" || $member_data->{type} eq "bool8" )
			{
				$member_data->{size} = $member_data->{align} = $native;
			}
			elsif ( $member_data->{type} eq "int" || $member_data->{type} eq "enum" || $member_data->{type} eq "bool4" )
			{
				$member_data->{size} = $member_data->{align} = 4;
			}
			elsif ( $member_data->{type} eq "short" )
			{
				$member_data->{size} = $member_data->{align} = 2;
			}
			elsif ( $member_data->{type} =~ "/^u?char$/" || $member_data->{type} eq "bool1" )
			{
				$member_data->{size} = $member_data->{align} = 1;
			}
			elsif ( $member_data->{type} =~ /^u?char\[(\d+)\]$/ )
			{
				$member_data->{size} = $1;
				$member_data->{align} = 1;
			}
			else
			{
				Fatal( "Unexpected type '".$member_data->{type}."' found in shared data definition." );
			}

			if ( $member_data->{align} > 1 && ($offset%$member_data->{align}) > 0 )
			{
				$offset += ($member_data->{align} - ($offset%$member_data->{align}));
			}
			$member_data->{offset} = $offset;
			$offset += $member_data->{size}
		}
		$section_data->{size} = $offset - $section_data->{offset};
	}

	$mem_size = $offset;
}

&zmMemInit();

sub zmMemVerify( $ )
{
	my $monitor = shift;
	if ( !zmMemAttach( $monitor, $mem_size ) )
	{
		return( undef );
	}

    my $mem_key = zmMemKey( $monitor );
	if ( !defined($mem_verified->{$mem_key}) )
	{
		my $sd_size = zmMemRead( $monitor, "shared_data:size", 1 );
		if ( $sd_size != $mem_data->{shared_data}->{size} )
		{
			if ( $sd_size )
			{
				Error( "Shared data size conflict in shared_data for monitor ".$monitor->{Name}.", expected ".$mem_data->{shared_data}->{size}.", got ".$sd_size );
			}
			else
			{
				Debug( "Shared data size conflict in shared_data for monitor ".$monitor->{Name}.", expected ".$mem_data->{shared_data}->{size}.", got ".$sd_size );
			}
			return( undef );
		}
		my $td_size = zmMemRead( $monitor, "trigger_data:size", 1 );
		if ( $td_size != $mem_data->{trigger_data}->{size} )
		{
			if ( $td_size )
			{
				Error( "Shared data size conflict in trigger_data for monitor ".$monitor->{Name}.", expected ".$mem_data->{triggger_data}->{size}.", got ".$td_size );
			}
			else
			{
				Debug( "Shared data size conflict in trigger_data for monitor ".$monitor->{Name}.", expected ".$mem_data->{triggger_data}->{size}.", got ".$td_size );
			}
			return( undef );
		}
		$mem_verified->{$mem_key} = !undef;
	}
	return( !undef );
}

sub zmMemRead( $$;$ )
{
	my $monitor = shift;
	my $fields = shift;
	my $nocheck = shift;

	if ( !($nocheck || zmMemVerify( $monitor )) )
	{
		return( undef );
	}

	if ( !ref($fields) )
	{
		$fields = [ $fields ];
	}
	my @values;
	foreach my $field ( @$fields )
	{
		my ( $section, $element ) = split( /[\/:.]/, $field );
		Fatal( "Invalid shared data selector '$field'" ) if ( !$section || !$element );

		my $offset = $mem_data->{$section}->{contents}->{$element}->{offset};
		my $type = $mem_data->{$section}->{contents}->{$element}->{type};
		my $size = $mem_data->{$section}->{contents}->{$element}->{size};

		my $data = zmMemGet( $monitor, $offset, $size );
        if ( !defined($data) )
        {
            Error( "Unable to read '$field' from memory for monitor ".$monitor->{Id} );
            zmMemInvalidate( $monitor );
            return( undef );
        }
		my $value;
		if ( $type eq "long" || $type eq "time_t" || $type eq "size_t" || $type eq "bool8" )
		{
			( $value ) = unpack( "l!", $data );
		}
		elsif ( $type eq "int" || $type eq "enum" || $type eq "bool4" )
		{
			( $value ) = unpack( "l", $data );
		}
		elsif ( $type eq "short" )
		{
			( $value ) = unpack( "s", $data );
		}
		elsif ( $type eq "char" || $type eq "bool1" )
		{
			( $value ) = unpack( "c", $data );
		}
		elsif ( $type eq "uchar" )
		{
			( $value ) = unpack( "C", $data );
		}
		elsif ( $type =~ /^char\[\d+\]$/ )
		{
			( $value ) = unpack( "Z".$size, $data );
		} 
		elsif ( $type =~ /^uchar\[\d+\]$/ )
		{
			( $value ) = unpack( "C".$size, $data );
		} 
		else
		{
			Fatal( "Unexpected type '".$type."' found for '".$field."'" );
		}
		push( @values, $value );
	}
	if ( wantarray() )
	{
		return( @values )
	}
	return( $values[0] );
}

sub zmMemInvalidate( $ )
{
	my $monitor = shift;
    my $mem_key = zmMemKey($monitor);
    if ( $mem_key )
    {
        delete $mem_verified->{$mem_key};
        zmMemDetach( $monitor );
    }
}

sub zmMemTidy()
{
    zmMemClean();
}

sub zmMemWrite( $$;$ )
{
	my $monitor = shift;
	my $field_values = shift;
	my $nocheck = shift;

	if ( !($nocheck || zmMemVerify( $monitor )) )
	{
		return( undef );
	}

	while ( my ( $field, $value ) = each( %$field_values ) )
	{
		my ( $section, $element ) = split( /[\/:.]/, $field );
		Fatal( "Invalid shared data selector '$field'" ) if ( !$section || !$element );

		my $offset = $mem_data->{$section}->{contents}->{$element}->{offset};
		my $type = $mem_data->{$section}->{contents}->{$element}->{type};
		my $size = $mem_data->{$section}->{contents}->{$element}->{size};

		my $data;
		if ( $type eq "long" || $type eq "time_t" || $type eq "size_t" || $type eq "bool8" )
		{
			$data = pack( "l!", $value );
		}
		elsif ( $type eq "int" || $type eq "enum" || $type eq "bool4" )
		{
			$data = pack( "l", $value );
		}
		elsif ( $type eq "short" )
		{
			$data = pack( "s", $value );
		}
		elsif ( $type eq "char" || $type eq "bool1" )
		{
			$data = pack( "c", $value );
		}
		elsif ( $type eq "uchar" )
		{
			$data = pack( "C", $value );
		}
		elsif ( $type =~ /^char\[\d+\]$/ )
		{
			$data = pack( "Z".$size, $value );
		}
		elsif ( $type =~ /^uchar\[\d+\]$/ )
		{
			$data = pack( "C".$size, $value );
		}
		else
		{
			Fatal( "Unexpected type '".$type."' found for '".$field."'" );
		}

        if ( !zmMemPut( $monitor, $offset, $size, $data ) )
        {
            Error( "Unable to write '$value' to '$field' in memory for monitor ".$monitor->{Id} );
            zmMemInvalidate( $monitor );
            return( undef );
        }
	}
	return( !undef );
}

sub zmGetMonitorState( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:state" ) );
}

sub zmGetAlarmLocation( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, [ "shared_data:alarm_x", "shared_data:alarm_y" ] ) );
}

sub zmSetControlState( $$ )
{
	my $monitor = shift;
	my $control_state = shift;

	zmMemWrite( $monitor, { "shared_data:control_state" => $control_state } );
}

sub zmGetControlState( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:control_state" ) );
}

sub zmSaveControlState( $$ )
{
	my $monitor = shift;
	my $control_state = shift;

	zmSetControlState( $monitor, freeze( $control_state ) );
}

sub zmRestoreControlState( $ )
{
	my $monitor = shift;

	return( thaw( zmGetControlState( $monitor ) ) );
}

sub zmIsAlarmed( $ )
{
	my $monitor = shift;

	my $state = zmGetMonitorState( $monitor );

	return( $state == STATE_ALARM );
}

sub zmInAlarm( $ )
{
	my $monitor = shift;

	my $state = zmGetMonitorState( $monitor );

	return( $state == STATE_ALARM || $state == STATE_ALERT );
}

sub zmHasAlarmed( $$ )
{
	my $monitor = shift;
	my $last_event_id = shift;

	my ( $state, $last_event ) = zmMemRead( $monitor, [ "shared_data:state", "shared_data:last_event" ] );

	if ( $state == STATE_ALARM || $state == STATE_ALERT )
	{
		return( $last_event );
	}
	elsif( $last_event != $last_event_id )
	{
		return( $last_event );
	}
	return( undef );
}

sub zmGetLastEvent( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:last_event" ) );
}

sub zmGetLastWriteTime( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:last_write_time" ) );
}

sub zmGetLastReadTime( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:last_read_time" ) );
}

sub zmGetMonitorActions( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "shared_data:action" ) );
}

sub zmMonitorEnable( $ )
{
	my $monitor = shift;

	my $action = zmMemRead( $monitor, "shared_data:action" );
	$action |= ACTION_SUSPEND;
	zmMemWrite( $monitor, { "shared_data:action" => $action } );
}

sub zmMonitorDisable( $ )
{
	my $monitor = shift;

	my $action = zmMemRead( $monitor, "shared_data:action" );
	$action |= ACTION_RESUME;
	zmMemWrite( $monitor, { "shared_data:action" => $action } );
}

sub zmMonitorSuspend( $ )
{
	my $monitor = shift;

	my $action = zmMemRead( $monitor, "shared_data:action" );
	$action |= ACTION_SUSPEND;
	zmMemWrite( $monitor, { "shared_data:action" => $action } );
}

sub zmMonitorResume( $ )
{
	my $monitor = shift;

	my $action = zmMemRead( $monitor, "shared_data:action" );
	$action |= ACTION_RESUME;
	zmMemWrite( $monitor, { "shared_data:action" => $action } );
}

sub zmGetTriggerState( $ )
{
	my $monitor = shift;

	return( zmMemRead( $monitor, "trigger_data:trigger_state" ) );
}

sub zmTriggerEventOn( $$$;$$ )
{
	my $monitor = shift;
	my $score = shift;
	my $cause = shift;
	my $text = shift;
	my $showtext = shift;

	my $values = {
		"trigger_data:trigger_score" => $score,
		"trigger_data:trigger_cause" => $cause,
	};
	$values->{"trigger_data:trigger_text"} = $text if ( defined($text) );
	$values->{"trigger_data:trigger_showtext"} = $showtext if ( defined($showtext) );
	$values->{"trigger_data:trigger_state"} = TRIGGER_ON; # Write state last so event not read incomplete

	zmMemWrite( $monitor, $values );
}

sub zmTriggerEventOff( $ )
{
	my $monitor = shift;

	my $values = {
		"trigger_data:trigger_state"    => TRIGGER_OFF,
		"trigger_data:trigger_score"    => 0,
		"trigger_data:trigger_cause"    => "",
		"trigger_data:trigger_text"     => "",
		"trigger_data:trigger_showtext" => "",
	};

	zmMemWrite( $monitor, $values );
}

sub zmTriggerEventCancel( $ )
{
	my $monitor = shift;

	my $values = {
		"trigger_data:trigger_state"    => TRIGGER_CANCEL,
		"trigger_data:trigger_score"    => 0,
		"trigger_data:trigger_cause"    => "",
		"trigger_data:trigger_text"     => "",
		"trigger_data:trigger_showtext" => "",
	};

	zmMemWrite( $monitor, $values );
}

sub zmTriggerShowtext( $$ )
{
	my $monitor = shift;
	my $showtext = shift;

	my $values = {
		"trigger_data:trigger_showtext" => $showtext,
	};

	zmMemWrite( $monitor, $values );
}

1;
__END__

=head1 NAME

ZoneMinder::MappedMem - ZoneMinder Mapped Memory access module

=head1 SYNOPSIS

  use ZoneMinder::MappedMem;
  use ZoneMinder::MappedMem qw(:all);

  if ( zmMemVerify( $monitor ) )
  {
    $state = zmGetMonitorState( $monitor );
    if ( $state == STATE_ALARM )
    {
      ...
    }
  }

  ( $lri, $lwi ) = zmMemRead( $monitor, [ "shared_data:last_read_index", "shared_data:last_write_index" ] );
  zmMemWrite( $monitor, { "trigger_data:trigger_showtext" => "Some Text" } );

=head1 DESCRIPTION

The ZoneMinder:MappedMem module contains methods for accessing and writing to mapped memory as well as helper methods for common operations.

The core elements of ZoneMinder used mapped memory to allow multiple access to resources. Although ZoneMinder scripts have used this information before, up until now it was difficult to access and prone to errors. This module introduces a common API for mapped memory access (both reading and writing) making it a lot easier to customise scripts or even create your own.

All the methods listed below require a 'monitor' parameter. This must be a reference to a hash with at least the 'Id' field set to the monitor id of the mapped memory you wish to access. Using database methods to select the monitor details will also return this kind of data. Some of the mapped memory methods will add and amend new fields to this hash.

=over 4

=head1 METHODS

=item zmMemVerify ( $monitor );

Verify that the mapped memory of the monitor given exists and is valid. It will return an undefined value if it is not valid. You should generally call this method first before using any of the other methods, but most of the remaining methods will also do so if the memory has not already been verified.

=item zmMemInvalidate ( $monitor );

Following an error, reset the mapped memory ids and attempt to reverify on the next operation. This is mostly used when a mapped memory segment has gone away and been recreated with a different id.

=item zmMemRead ( $monitor, $readspec );

This method is used to read data from mapped memory attached to the given monitor. The mapped memory will be verified if it has not already been. The 'readspec' must either be a string of the form "<section>:<field>" or a reference to an array of strings of the same format. In the first case a single value is returned, in the latter case a list of values is return. Errors will cause undefined to be returned. The allowable sections and field names are described below.

=item zmMemWrite ( $monitor, $writespec );

This method is used to write data to mapped memory attached to the given monitor. The mapped memory will be verified if it has not already been. The 'writespec' must be a reference to a hash with keys of the form "<section>:<field>" and values as the data to be written. Errors will cause undefined to be returned, otherwise a non-undefined value will be returned. The allowable sections and field names are described below.

=item $state = zmGetMonitorState ( $monitor );

Return the current state of the given monitor. This is an integer value and can be compared with the STATE constants given below.

=item $event_id = zmGetLastEvent ( $monitor );

Return the event id of the last event that the monitor generated, or 0 if no event has been generated by the current monitor process.

=item zmIsAlarmed ( $monitor );

Return 1 if the monitor given is currently in an alarm state, 0 otherwise.

=item zmInAlarm ( $monitor );

Return 1 if the monitor given is currently in an alarm or alerted state, 0 otherwise.

=item zmHasAlarmed ( $monitor );

Return 1 if the given monitor is in an alarm state, or has been in an alarm state since the last call to this method.

=item ( $x, $y ) = zmGetAlarmLocation ( $monitor );

Return an x,y pair indicating the image co-ordinates of the centre of the last motion event generated by the given monitor. If no event has been generated by the current monitor process, or the alarm was not motion related, returns -1,-1.

=item zmGetLastWriteTime ( $monitor );

Returns the time (in utc seconds) since the last image was captured by the given monitor and written to shared memory, or 0 otherwise.

=item zmGetLastReadTime ( $monitor );

Returns the time (in utc seconds) since the last image was read from shared memory by the analysis daemon of the given monitor, or 0 otherwise or if the monitor is in monitor only mode.

=item zmMonitorSuspend ( $monitor );

Suspend the given monitor from generating events caused by motion. This method can be used to prevent camera actions such as panning or zooming from causing events. If configured to do so, the monitor may automatically resume after a defined period.

=item zmMonitorResume ( $monitor );

Allow the given monitor to resume generating events caused by motion.

=item zmTriggerEventOn ( $monitor, $score, $cause [, $text, $showtext ] );

Trigger the given monitor to generate an event. You must supply an event score and a cause string indicating the reason for the event. You may also supply a text string containing further details about the event and a showtext string which may be included in the timestamp annotation on any images captured during the event, if configured to do so.

=item zmTriggerEventOff ( $monitor );

Trigger the given monitor to not generate any events. This method does not cancel zmTriggerEventOn, but is exclusive to it. This method is intended to allow external triggers to prevent normal events being generated by monitors in the same way as zmMonitorSuspend but applies to all events and not just motion, and is intended for longer timescales than are appropriate for suspension.

=item zmTriggerEventCancel ( $monitor );

Cancel any previous trigger on or off requests. This stops a triggered alarm if it exists from a previous 'on' and allows events to be generated once more following a previous 'off'.

=item zmTriggerShowtext ( $monitor, $showtest );

Indicate that the given text should be displayed in the timestamp annotation on any images captured, if the format of the annotation string defined for the monitor permits.

=head1 DATA

The data fields in mapped memory that may be accessed are as follows. There are two main sections, shared_data which is general data and trigger_data which is used for event triggering. Whilst reading from these fields is harmless, extreme care must be taken when writing to mapped memory, especially in the shared_data section as this is normally written to only by monitor capture and analysis processes.

  shared_data         The general mapped memory section
    size              The size, in bytes, of this section
    valid             Flag indicating whether this section has been initialised
    active            Flag indicating whether this monitor is active (enabled/disabled)
    signal            Flag indicating whether this monitor is reciving a valid signal
    state             The current monitor state, see the STATE constants below
    last_write_index  The last index, in the image buffer, that an image has been saved to
    last_read_index   The last index, in the image buffer, that an image has been analysed from
    last_write_time   The time (in utc seconds) when the last image was captured
    last_read_time    The time (in utc seconds) when the last image was analysed
    last_event        The id of the last event generated by the monitor analysis process, 0 if none
    action            The monitor actions bitmask, see the ACTION constants below
    brightness        Read/write location for the current monitor brightness
    hue               Read/write location for the current monitor hue
    colour            Read/write location for the current monitor colour
    contrast          Read/write location for the current monitor contrast
    alarm_x           Image x co-ordinate (from left) of the centre of the last motion event, -1 if none
    alarm_y           Image y co-ordinate (from top) of the centre of the last motion event, -1 if none

  trigger_data        The triggered event mapped memory section
    size              The size, in bytes of this section
    trigger_state     The current trigger state, see the TRIGGER constants below
    trigger_score     The current triggered event score
    trigger_cause     The current triggered event cause string
    trigger_text      The current triggered event descriptive text string
    trigger_showtext  The triggered text that will be displayed on captured image timestamps

=head1 CONSTANTS

The following constants are used by the methods above, but can also be used by user scripts if required.

=item STATE_IDLE STATE_PREALARM STATE_ALARM STATE_ALERT STATE_TAPE

These constants define the state of the monitor with respect to alarms and events. They are used in the shared_data:state field.

=item ACTION_GET ACTION_SET ACTION_RELOAD ACTION_SUSPEND ACTION_RESUME

These constants defines the various values that can exist in the shared_data:action field. This is a bitmask which when non-zero defines an action that an executing monitor process should take. ACTION_GET requires that the current values of brightness, contrast, colour and hue are taken from the camera and written to the equivalent mapped memory fields. ACTION_SET implies the reverse, that the values in mapped memory should be written to the camera. ACTION_RELOAD signal that the monitor process should reload itself from the database in case any settings have changed there. ACTION_SUSPEND signals that a monitor should stop exaiming images for motion, though other alarms may still occur. ACTION_RESUME sigansl that a monitor should resume motion detectiom.

=item TRIGGER_CANCEL TRIGGER_ON TRIGGER_OFF 

These constants are used in the definition of external triggers. TRIGGER_CANCEL is used to indicated that any previous trigger settings should be cancelled, TRIGGER_ON signals that an alarm should be created (or continued)) as a result of the current trigger and TRIGGER_OFF signals that the trigger should prevent any alarms from being generated. See the trigger methods above for further details.

=head1 EXPORT

None by default.
The :constants tag will export the mapped memory constants which mostly define enumerations for the variables held in memory
The :functions tag will export the mapped memory access functions.
The :all tag will export all above symbols.


=head1 SEE ALSO

http://www.zoneminder.com

=head1 AUTHOR

Philip Coombes, E<lt>philip.coombes@zoneminder.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001-2008  Philip Coombes

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
