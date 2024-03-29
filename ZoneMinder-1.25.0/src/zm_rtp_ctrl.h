//
// ZoneMinder RTCP Class Interface, $Date: 2010-07-04 19:00:35 +0100 (Sun, 04 Jul 2010) $, $Revision: 3087 $
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

#ifndef ZM_RTP_CTRL_H
#define ZM_RTP_CTRL_H

#include "zm_rtp.h"
#include "zm_comms.h"
#include "zm_thread.h"

// Defined in ffmpeg rtp.h
//#define RTP_MAX_SDES 255      // maximum text length for SDES

// Big-endian mask for version, padding bit and packet type pair
#define RTCP_VALID_MASK (0xc000 | 0x2000 | 0xfe)
#define RTCP_VALID_VALUE ((RTP_VERSION << 14) | RTCP_SR)

class RtspThread;
class RtpSource;

class RtpCtrlThread : public Thread
{
friend class RtspThread;

private:
    typedef enum
    {
        RTCP_SR   = 200,
        RTCP_RR   = 201,
        RTCP_SDES = 202,
        RTCP_BYE  = 203,
        RTCP_APP  = 204
    } RtcpType;

    typedef enum
    {
        RTCP_SDES_END   = 0,
        RTCP_SDES_CNAME = 1,
        RTCP_SDES_NAME  = 2,
        RTCP_SDES_EMAIL = 3,
        RTCP_SDES_PHONE = 4,
        RTCP_SDES_LOC   = 5,
        RTCP_SDES_TOOL  = 6,
        RTCP_SDES_NOTE  = 7,
        RTCP_SDES_PRIV  = 8
    } RtcpSdesType;

    struct RtcpCommonHeader
    {
        uint8_t count:5;      // varies by packet type
        uint8_t p:1;          // padding flag
        uint8_t version:2;    // protocol version
        uint8_t pt;           // RTCP packet type
        uint16_t lenN;        // pkt len in words, w/o this word, network order 
    };

    // Reception report block
    struct RtcpRr
    {
        uint32_t ssrcN;       // data source being reported
        int32_t lost:24;     // cumul. no. pkts lost (signed!)
        uint32_t fraction:8;  // fraction lost since last SR/RR
        uint32_t lastSeqN;    // extended last seq. no. received, network order
        uint32_t jitterN;     // interarrival jitter, network order
        uint32_t lsrN;        // last SR packet from this source, network order
        uint32_t dlsrN;       // delay since last SR packet, network order
    };

    // SDES item
    struct RtcpSdesItem
    {
        uint8_t type;         // type of item (rtcp_sdes_type_t)
        uint8_t len;          // length of item (in octets)
        char data[];     // text, not null-terminated
    };

    // RTCP packet
    struct RtcpPacket
    {
        RtcpCommonHeader header; // common header
        union
        {
            // Sender Report (SR)
            struct Sr
            {
                uint32_t    ssrcN;    // sender generating this report, network order
                uint32_t    ntpSecN;  // NTP timestamp, network order
                uint32_t    ntpFracN;
                uint32_t    rtpTsN;   // RTP timestamp, network order
                uint32_t    pSentN;   // packets sent, network order
                uint32_t    oSentN;   // octets sent, network order
                RtcpRr rr[];     // variable-length list
            } sr;

            // Reception Report (RR)
            struct Rr
            {
                uint32_t ssrcN;        // receiver generating this report
                RtcpRr rr[];     // variable-length list
            } rr;

            // source description (SDES)
            struct Sdes
            {
                uint32_t srcN;        // first SSRC/CSRC
                RtcpSdesItem item[]; // list of SDES items
            } sdes;

            // BYE
            struct Bye
            {
                uint32_t srcN[];     // list of sources
                // can't express trailing text for reason (what does this mean? it's not even english!)
            } bye;
         } body;
    };

private:
    RtspThread &mRtspThread;
    RtpSource &mRtpSource;
    int mPort;
    bool mStop;

private:
    int recvPacket( const unsigned char *packet, ssize_t packetLen );
    int generateRr( const unsigned char *packet, ssize_t packetLen );
    int generateSdes( const unsigned char *packet, ssize_t packetLen );
    int generateBye( const unsigned char *packet, ssize_t packetLen );
    int recvPackets( unsigned char *buffer, ssize_t nBytes );
    int run();

public:
    RtpCtrlThread( RtspThread &rtspThread, RtpSource &rtpSource );

    void stop() 
    {
        mStop = true;
    }
};

#endif // ZM_RTP_CTRL_H
