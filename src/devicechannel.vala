/* ex:ts=4:sw=4:sts=4:et */
/* -*- tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/**
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * AUTHORS
 * Maciek Borzecki <maciek.borzecki (at] gmail.com>
 */

using MConn;

/**
 * Device communication channel
 *
 * Automatically handle channel encoding.
 */
class DeviceChannel : Object {

	public signal void disconnected();
	public signal void packet_received(Packet pkt);

	private InetSocketAddress _isa = null;
	private SocketConnection _conn = null;
	private DataOutputStream _dout = null;
	private DataInputStream _din = null;
	private uint _srcid = 0;

	// channel encryption method
	private Crypt _crypt = null;

	public DeviceChannel(InetAddress host, uint port, Crypt crypt) {
		_isa = new InetSocketAddress(host, (uint16) port);
		_crypt = crypt;
	}

	~DeviceChannel() {
		debug("channel destroyed");
	}

	public async bool open() {
		assert(this._isa != null);

		debug("connect to %s:%u", _isa.address.to_string(), _isa.port);

		var client = new SocketClient();
		try {
			_conn = yield client.connect_async(_isa);
		} catch (Error e) {
			//
			critical("failed to connect to %s:%u: %s",
					 _isa.address.to_string(), _isa.port,
					 e.message);
			// emit disconnected
			return false;
		}

		debug("connected to %s:%u", _isa.address.to_string(), _isa.port);

		// use data streams
		_dout = new DataOutputStream(_conn.output_stream);
		_din = new DataInputStream(_conn.input_stream);
		// messages end with \n\n
		_din.set_newline_type(DataStreamNewlineType.LF);

		// setup socket monitoring
		Socket sock = _conn.get_socket();
		// enable keepalive
		sock.set_keepalive(true);
		// prep source for monitoring events
		SocketSource source = sock.create_source(IOCondition.IN | IOCondition.ERR |
												 IOCondition.HUP);
		source.set_callback((src, cond) => {
				this._io_ready.begin(cond);
				return true;
			});
		// attach source
		_srcid = source.attach(null);

		return true;
	}

	public async void close() {
		debug("closing connection");

		if (_srcid > 0) {
			Source.remove(_srcid);
			_srcid = 0;
		}

		try {
			if (_din != null)
				_din.close();
		} catch (Error e) {
			critical("failed to close data input: %s", e.message);
		}
		try {
			if (_dout != null)
				_dout.close();
		} catch (Error e) {
			critical("failed to close data output: %s", e.message);
		}
		try {
			if (_conn != null)
				_conn.close();
		} catch (Error e) {
			critical("failed to close connection: %s", e.message);
		}
		_din = null;
		_dout = null;
		_conn = null;
	}

	/**
	 * send:
	 * Possibly blocking
	 *
	 * @param: instance of Packet
	 **/
	public async void send(Packet pkt) {
		string to_send = pkt.to_string() + "\n";
		debug("send data: %s", to_send);
		// _dout.put_string(data);
		try {
			_dout.put_string(to_send);
		} catch (IOError e) {
			critical("failed to send message: %s", e.message);
			// TODO disconnect?
		}
	}

	/**
	 * receive:
	 * Try to receive some data from channel
	 *
	 * @return false if channel was closed, true otherwise
	 */
	public async bool receive() {
		size_t line_len;
		string data = null;
		// read line up to newline
		try {
			data = yield _din.read_upto_async("\n", -1,
											  Priority.DEFAULT,
											  null,
											  out line_len);
			// expecting \n\n
			_din.read_byte();
			_din.read_byte();
		} catch (IOError ie) {
			debug("I/O error: %s", ie.message);
		}

		if (data == null) {
			debug("connection closed?");
			return false;
		}

		debug("received line: %s", data);

		Packet pkt = Packet.new_from_data(data);
		if (pkt == null) {
			critical("failed to build packet from data");
			// data was received, hence connection is still alive
			return true;
		}

		handle_packet(pkt);

		return true;
	}

	private async void _io_ready(uint flags) {
		debug("check for IO, conditions: 0x%x", flags);
		bool res = yield this.receive();

		if (res == false) {
			// disconnected
			disconnected();
		}
	}

	private void handle_packet(Packet pkt) {
		debug("handle packet of type: %s", pkt.pkt_type);
		if (pkt.pkt_type == Packet.ENCRYPTED) {
			handle_encrypted_packet(pkt);
		} else {
			// signal that we got a packet
			packet_received(pkt);
		}
	}

	private void handle_encrypted_packet(Packet pkt) {
		// Ecypted packets have 'data' member in body. The 'data'
		// member is an array of strings, each string is base64
		// encoded data, of length appropriate for channel ecryption
		// method.
		Json.Array arr = pkt.body.get_array_member("data");
		if (arr == null) {
			critical("missing data member in encrypted packet");
			return;
		}

		bool failed = false;
		var msgbytes = new ByteArray();
		arr.foreach_element((a, i, node) => {
				// exit early
				if (failed == true)
					return;

				debug("node data: %s", node.get_string());
				// encrypted data is base64 encoded
				uchar[] data = Base64.decode(node.get_string());
				var dbytes = new Bytes.take(data);
				try {
					ByteArray decrypted = this._crypt.decrypt(dbytes);
					debug("data length: %zu", decrypted.data.length);
					msgbytes.append(decrypted.data);
				} catch (Error e) {
					critical("decryption failed: %s", e.message);
					failed = true;
				}
			});
		// data should be complete now
		debug("total length of packet data: %zu", msgbytes.len);
		// make sure there is \0 at the end
		msgbytes.append({'\0'});
		string decrypted_data = ((string)msgbytes.data).dup();
		debug("decrypted data: %s", decrypted_data);

		Packet dec_pkt = Packet.new_from_data(decrypted_data);
		if (dec_pkt == null) {
			critical("failed to parse decrypted packet");
		} else {
			packet_received(dec_pkt);
		}
	}
}