<?php
//
// ZoneMinder web configuration file, $Date: 2011-06-21 10:19:10 +0100 (Tue, 21 Jun 2011) $, $Revision: 3459 $
// Copyright (C) 2001-2008 Philip Coombes
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
//

//
// This section contains options substituted by the zmconfig.pl utility, do not edit these directly
//
define( "ZM_CONFIG", "/etc/zm/zm.conf" );               // Path to config file

$configFile = ZM_CONFIG;
$localConfigFile = basename($configFile);
if ( file_exists( $localConfigFile ) && filesize( $localConfigFile ) > 0 )
{
    if ( php_sapi_name() == 'cli' && empty($_SERVER['REMOTE_ADDR']) )
        print( "Warning, overriding installed $localConfigFile file with local copy\n" );
    else
        error_log( "Warning, overriding installed $localConfigFile file with local copy" );
    $configFile = $localConfigFile;
}
                             
$cfg = fopen( $configFile, "r") or die("Could not open config file.");
while ( !feof($cfg) )
{
    $str = fgets( $cfg, 256 );
    if ( preg_match( '/^\s*$/', $str ))
        continue;
    elseif ( preg_match( '/^\s*#/', $str ))
        continue;
    elseif ( preg_match( '/^\s*([^=\s]+)\s*=\s*(.+?)\s*$/', $str, $matches ))
        define( $matches[1], $matches[2] );
}
fclose( $cfg );

//
// This section is options normally derived from other options or configuration
//
define( "ZMU_PATH", ZM_PATH_BIN."/zmu" );               // Local path to the ZoneMinder Utility

//
// If setup supports Video 4 Linux v2 and/or v1
//
define( "ZM_HAS_V4L2", "1" );               // V4L2 support enabled
define( "ZM_HAS_V4L1", "0" );               // V4L1 support enabled
define( "ZM_HAS_V4L", "1" );                 // V4L support enabled

//
// If PCRE dev libraries are installed
//
define( "ZM_PCRE", "1" );                       // PCRE support enabled

//
// Alarm states
//
define( "STATE_IDLE", 0 );
define( "STATE_PREALARM", 1 );
define( "STATE_ALARM", 2 );
define( "STATE_ALERT", 3 );
define( "STATE_TAPE", 4 );

//
// DVR Control Commands
//

define( "MSG_CMD", 1 );
define( "MSG_DATA_WATCH", 2 );
define( "MSG_DATA_EVENT", 3 );

define( "CMD_NONE", 0 );
define( "CMD_PAUSE", 1 );
define( "CMD_PLAY", 2 );
define( "CMD_STOP", 3 );
define( "CMD_FASTFWD", 4 );
define( "CMD_SLOWFWD", 5 );
define( "CMD_SLOWREV", 6 );
define( "CMD_FASTREV", 7 );
define( "CMD_ZOOMIN", 8 );
define( "CMD_ZOOMOUT", 9 );
define( "CMD_PAN", 10 );
define( "CMD_SCALE", 11 );
define( "CMD_PREV", 12 );
define( "CMD_NEXT", 13 );
define( "CMD_SEEK", 14 );
define( "CMD_VARPLAY", 15 );
define( "CMD_QUERY", 99 );

//
// These are miscellaneous options you won't normally need to change
//
define( "MAX_EVENTS", 10 );                             // The maximum number of events to show in the monitor event listing
define( "RATE_BASE", 100 );                             // The additional scaling factor used to help get fractional rates in integer format
define( "SCALE_BASE", 100 );                            // The additional scaling factor used to help get fractional scales in integer format

//
// Date and time formats, eventually some of these may end up in the language files
//
define( "DATE_FMT_CONSOLE_LONG", "D jS M, g:ia" );      // This is the main console date/time, date() or strftime() format
define( "DATE_FMT_CONSOLE_SHORT", "%H:%M" );            // This is the xHTML console date/time, date() or strftime() format

define( "STRF_FMT_DATETIME_DB", "%Y-%m-%d %H:%M:%S" );  // Strftime format for database queries, don't change

define( "STRF_FMT_DATETIME", "%c" );                    // Strftime locale aware format for dates with times
define( "STRF_FMT_DATE", "%x" );                        // Strftime locale aware format for dates without times
define( "STRF_FMT_TIME", "%X" );                        // Strftime locale aware format for times without dates

define( "STRF_FMT_DATETIME_SHORT", "%y/%m/%d %H:%M:%S" ); // Strftime shorter format for dates with time, not locale aware
define( "STRF_FMT_DATETIME_SHORTER", "%m/%d %H:%M:%S" ); // Strftime shorter format for dates with time, not locale aware, used where space is tight

define( "MYSQL_FMT_DATETIME_SHORT", "%y/%m/%d %H:%i:%S" ); // MySQL date_format shorter format for dates with time

require_once( 'database.php' );
loadConfig();

$GLOBALS['defaultUser'] = array(
    "Username"  => "admin",
    "Password"  => "",
    "Language"  => "",
    "Enabled"   => 1,
    "Stream"    => 'View',
    "Events"    => 'Edit',
    "Control"   => 'Edit',
    "Monitors"  => 'Edit',
    "Devices"   => 'Edit',
    "System"    => 'Edit',
    "MaxBandwidth" => "",
    "MonitorIds"   => false
);

function loadConfig( $defineConsts=true )
{
    global $config;
    global $configCats;

    $config = array();
    $configCat = array();

    $sql = "select * from Config order by Id asc";
    $result = mysql_query( $sql );
    if ( !$result )
        echo mysql_error();
    $monitors = array();
    while( $row = mysql_fetch_assoc( $result ) )
    {
        if ( $defineConsts )
            define( $row['Name'], $row['Value'] );
        $config[$row['Name']] = $row;
        if ( !($configCat = &$configCats[$row['Category']]) )
        {
            $configCats[$row['Category']] = array();
            $configCat = &$configCats[$row['Category']];
        }
        $configCat[$row['Name']] = $row;
    }
    //print_r( $config );
    //print_r( $configCats );
}

?>
