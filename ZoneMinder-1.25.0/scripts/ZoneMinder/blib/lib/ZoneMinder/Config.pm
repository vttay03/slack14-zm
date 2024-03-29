# ==========================================================================
#
# ZoneMinder Config Module, $Date: 2008-07-25 10:48:16 +0100 (Fri, 25 Jul 2008) $, $Revision: 2612 $
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
package ZoneMinder::Config;

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
our @EXPORT_CONFIG; # Get populated by BEGIN

our %EXPORT_TAGS = (
	'constants' => [ qw(
		ZM_PID
	) ]
);
push( @{$EXPORT_TAGS{config}}, @EXPORT_CONFIG );
push( @{$EXPORT_TAGS{all}}, @{$EXPORT_TAGS{$_}} ) foreach keys %EXPORT_TAGS;

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw();

our $VERSION = $ZoneMinder::Base::VERSION;

use constant ZM_PID => "/var/run/zm/zm.pid"; # Path to the ZoneMinder run pid file
use constant ZM_CONFIG => "/etc/zm/zm.conf"; # Path to the ZoneMinder config file

use Carp;

# Load the config from the database into the symbol table
BEGIN
{
	no strict 'refs';

	my $config_file = ZM_CONFIG;
	( my $local_config_file = $config_file ) =~ s|^.*/|./|;
	if ( -s $local_config_file && -r $local_config_file )
	{
		print( STDERR "Warning, overriding installed $local_config_file file with local copy\n" );
		$config_file = $local_config_file;
	}
	open( CONFIG, "<".$config_file ) or croak( "Can't open config file '$config_file': $!" );
	foreach my $str ( <CONFIG> )
	{
		next if ( $str =~ /^\s*$/ );
		next if ( $str =~ /^\s*#/ );
        my ( $name, $value ) = $str =~ /^\s*([^=\s]+)\s*=\s*(.+?)\s*$/;
		$name =~ tr/a-z/A-Z/;
		*{$name} = sub { $value };
		push( @EXPORT_CONFIG, $name );
	}
	close( CONFIG );

	use DBI;
	my $dbh = DBI->connect( "DBI:mysql:database=".&ZM_DB_NAME.";host=".&ZM_DB_HOST, &ZM_DB_USER, &ZM_DB_PASS );
	my $sql = "select * from Config";
	my $sth = $dbh->prepare_cached( $sql ) or croak( "Can't prepare '$sql': ".$dbh->errstr() );
	my $res = $sth->execute() or croak( "Can't execute: ".$sth->errstr() );
	while( my $config = $sth->fetchrow_hashref() )
	{
		*{$config->{Name}} = sub { $config->{Value} };
		push( @EXPORT_CONFIG, $config->{Name} );
	}
	$sth->finish();
	$dbh->disconnect();
}

1;
__END__

=head1 NAME

ZoneMinder::Config - ZoneMinder configuration module.

=head1 SYNOPSIS

  use ZoneMinder::Config qw(:all);

=head1 DESCRIPTION

The ZoneMinder::Config module is used to import the ZoneMinder configuration from the database. It will do this at compile time in a BEGIN block and require access to the zm.conf file either in the current directory or in its defined location in order to determine database access details, configuration from this file will also be included. If the :all or :config tags are used then this configuration is exported into the namespace of the calling program or module.

Once the configuration has been imported then configuration variables are defined as constants and can be accessed directory by name, e.g.

 $lang = ZM_LANG_DEFAULT;

=head2 EXPORT

None by default.
The :constants tag will export the ZM_PID constant which details the location of the zm.pid file
The :config tag will export all configuration from the database as well as any from the zm.conf file
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
