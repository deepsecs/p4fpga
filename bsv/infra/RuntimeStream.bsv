// Copyright (c) 2016 Cornell University.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package Runtime;

import Library::*;
import RxChannel::*;
import TxChannel::*;
import HostChannel::*;
import StreamChannel::*;
import Channel::*;
import Gearbox::*;
import SharedBuff::*;
import PacketBuffer::*;
import Stream::*;
import StreamGearbox::*;
import XBar::*;
`include "ConnectalProjectConfig.bsv"
`include "Debug.defines"

typedef 512 DatapathWidth;
typedef TDiv#(DatapathWidth, ChannelWidth) BusRatio;

// FIXME: make this right
function Bit#(32) destOf (ByteStream#(64) x);
   // return egress_port in metadata
   return 0; //truncate(pack (x.data)) & 'hF;
endfunction

/*
   P4FPGA runtime consists of 5 types of channels and optional packet memory
   to acclerate packet re-entry
 */
interface Runtime#(numeric type nrx, numeric type ntx, numeric type nhs);
   interface Vector#(nrx, StreamInChannel) rxchan;
   interface Vector#(ntx, StreamOutChannel) txchan;
   interface Vector#(nhs, StreamInChannel) hostchan;
   // TODO: reentryChannel and dropChannel
   method Action set_verbosity (int verbosity);
endinterface
module mkRuntime#(Clock rxClock, Reset rxReset, Clock txClock, Reset txReset)(Runtime#(nrx, ntx, nhs))
   provisos(Add#(ntx, a__, 8)); // FIXME: make ntx == 8, caused by take()

   `PRINT_DEBUG_MSG

   function Put#(ByteStream#(64)) get_write_data(PacketBuffer#(64) buff);
      return buff.writeServer.writeData;
   endfunction

   let clock <- exposeCurrentClock();
   let reset <- exposeCurrentReset();

   Vector#(nhs, StreamInChannel) _hostchan <- genWithM(mkStreamInChannel);
   // FIXME: StreamRxChannel
   Vector#(nrx, StreamInChannel) _rxchan <- genWithM(mkStreamInChannel);//FIXME, clocked_by rxClock, reset_by rxReset);
   Vector#(ntx, StreamOutChannel) _txchan <- replicateM(mkStreamOutChannel(txClock, txReset));

   // drop streamed bytes on the floor
   //mkTieOff(_hostchan[0].writeClient.writeData);
   Vector#(nhs, StreamGearbox#(16, 32)) gearbox_up_16 <- replicateM(mkStreamGearboxUp());
   Vector#(nhs, StreamGearbox#(32, 64)) gearbox_up_32 <- replicateM(mkStreamGearboxUp());
   mapM(uncurry(mkConnection), zip(map(getWriteClient, _hostchan), map(getDataIn, gearbox_up_16)));
   mapM(uncurry(mkConnection), zip(map(getDataOut, gearbox_up_16), map(getDataIn, gearbox_up_32)));

   PacketBuffer#(64) input_queues <- mkPacketBuffer(); // input queue
   mkConnection(gearbox_up_32[0].dataout, input_queues.writeServer.writeData); // gearbox -> input queue
   mkConnection(input_queues.readServer.readLen, input_queues.readServer.readReq); // immediate transmit

   XBar#(64) xbar <- mkXBar(3, 0, destOf, mkMerge2x1_lru);
   mkConnection(input_queues.readServer.readData, xbar.input_ports[0]); // input queue -> xbar

   Vector#(8, PacketBuffer#(64)) output_queues <- replicateM(mkPacketBuffer()); // output queue
   mapM(uncurry(mkConnection), zip(map(getReadLen, output_queues), map(getReadReq, output_queues))); // immediate transmit

   Vector#(8, Get#(ByteStream#(64))) outvec = toVector(xbar.output_ports);
   Vector#(ntx, StreamGearbox#(64, 32)) gearbox_dn_32 <- replicateM(mkStreamGearboxDn());
   Vector#(ntx, StreamGearbox#(32, 16)) gearbox_dn_16 <- replicateM(mkStreamGearboxDn());
   //mapM_(mkTieOff, outvec); // want to see which idx is going out of
   mapM(uncurry(mkConnection), zip(outvec, map(get_write_data, output_queues))); // xbar -> output queue
   //mkConnection(output_queues.readServer.readData, getDataIn(gearbox_dn_32[0])); 
   mapM(uncurry(mkConnection), zip(map(getReadData, take(output_queues)), map(getDataIn, gearbox_dn_32))); // output queue -> gearbox

   mapM(uncurry(mkConnection), zip(map(getDataOut, gearbox_dn_32), map(getDataIn, gearbox_dn_16)));
   mapM(uncurry(mkConnection), zip(map(getDataOut, gearbox_dn_16), map(getWriteServer, _txchan)));
   //FIXME: must send metadata to _txchan to invoke transmit

   interface rxchan = _rxchan;
   interface txchan = _txchan;
   interface hostchan = _hostchan;
   method Action set_verbosity (int verbosity);
      //_rxchan.set_verbosity(verbosity);
      _txchan[0].set_verbosity(verbosity);
      _hostchan[0].set_verbosity(verbosity);
      cf_verbosity <= verbosity;
   endmethod
endmodule

endpackage
