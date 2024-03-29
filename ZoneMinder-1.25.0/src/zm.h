//
// ZoneMinder Core Interfaces, $Date: 2011-06-21 10:19:10 +0100 (Tue, 21 Jun 2011) $, $Revision: 3459 $
// $Copyright$
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

#ifndef ZM_H
#define ZM_H

#include "zm_config.h"
#include "zm_logger.h"

extern "C"
{
#if !HAVE_DECL_ROUND
double round(double);
#endif
}

#include <stdint.h>

#endif // ZM_H
