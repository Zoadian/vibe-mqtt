﻿/**
 *
 * /home/tomas/workspace/mqtt-d/source/mqttd/client.d
 *
 * Author:
 * Tomáš Chaloupka <chalucha@gmail.com>
 *
 * Copyright (c) 2015 Tomáš Chaloupka
 *
 * Boost Software License 1.0 (BSL-1.0)
 *
 * Permission is hereby granted, free of charge, to any person or organization obtaining a copy
 * of the software and accompanying documentation covered by this license (the "Software") to use,
 * reproduce, display, distribute, execute, and transmit the Software, and to prepare derivative
 * works of the Software, and to permit third-parties to whom the Software is furnished to do so,
 * all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including the above license
 * grant, this restriction and the following disclaimer, must be included in all copies of the Software,
 * in whole or in part, and all derivative works of the Software, unless such copies or derivative works
 * are solely in the form of machine-executable object code generated by a source language processor.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 * PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR ANYONE
 * DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */
module mqttd.client;

debug import std.stdio;

import mqttd.traits;
import mqttd.messages;
import mqttd.serialization;

import vibe.core.log;
import vibe.core.net: TCPConnection;
import vibe.core.stream;
import vibe.core.task;
import vibe.core.concurrency;
import vibe.utils.array : FixedRingBuffer;

import std.datetime;
import std.exception;
import std.string : format;
import std.traits;

enum MQTT_BROKER_DEFAULT_PORT = 1883u;
enum MQTT_BROKER_DEFAULT_SSL_PORT = 8883u;
enum MQTT_SESSION_MAX_PACKETS = ushort.max;
enum MQTT_CLIENT_ID = "vibe-mqtt"; /// default client identifier
enum MQTT_RETRY_DELAY = 10_000u; /// delay for retry publish, subscribe and unsubscribe for QoS Level 1 or 2 [ms]
enum MQTT_RETRY_ATTEMPTS = 3u; /// max publish, subscribe and unsubscribe retry for QoS Level 1 or 2


alias SessionContainer = FixedRingBuffer!(PacketContext, MQTT_SESSION_MAX_PACKETS);

/// MqttClient settings
struct Settings
{
    string host = "127.0.0.1"; /// message broker address
    ushort port = MQTT_BROKER_DEFAULT_PORT; /// message broker port
    string clientId = MQTT_CLIENT_ID; /// Client Id to identify within message broker (must be unique)
    string userName = null; /// optional user name to login with
    string password = null; /// user password
    int retryDelay = MQTT_RETRY_DELAY;
    int retryAttempts = MQTT_RETRY_ATTEMPTS; /// how many times will client try to resend QoS1 and QoS2 packets
}

/// MQTT packet state
enum PacketState
{
    queuedQos0, /// QOS = 0, Message queued
    queuedQos1, /// QOS = 1, Message queued
    queuedQos2, /// QOS = 2, Message queued
    waitForPuback, /// QOS = 1, PUBLISH sent, wait for PUBACK
    waitForPubrec, /// QOS = 2, PUBLISH sent, wait for PUBREC
    waitForPubrel, /// QOS = 2, PUBREC sent, wait for PUBREL
    waitForPubcomp, /// QOS = 2, PUBREL sent, wait for PUBCOMP
    sendPubrec, /// QOS = 2, start first phase handshake send PUBREC
    sendPubrel, /// QOS = 2, start second phase handshake send PUBREL
    sendPubcomp, /// QOS = 2, end second phase handshake send PUBCOMP
    sendPuback, /// QOS = 1, PUBLISH received, send PUBACK
    waitForSuback, /// (QOS = 1), SUBSCRIBE sent, wait for SUBACK
    waitForUnsuback, /// (QOS = 1), UNSUBSCRIBE sent, wait for UNSUBACK
    any /// for search purposes
}

/// Context for MQTT packet stored in Session
struct PacketContext
{
    PacketType packetType; /// MQTT packet content
    PacketState state; /// MQTT packet state
    public SysTime timestamp; /// Timestamp (for retry)
    public uint attempt; /// Attempt (for retry)
    /// MQTT packet id
    @property ushort packetId()
    {
        switch (packetType)
        {
            case PacketType.PUBLISH:
                return publish.packetId;
            case PacketType.SUBSCRIBE:
                return subscribe.packetId;
            case PacketType.UNSUBSCRIBE:
                return unsubscribe.packetId;
            default:
                assert(0, "Unsupported packet type");
        }
    }

    /// Context can hold different packet types
    union
    {
        Publish publish; /// Publish packet
        Subscribe subscribe; /// Subscribe packet
        Unsubscribe unsubscribe; /// Unsubscribe packet
    }

    ref PacketContext opAssign(ref PacketContext ctx)
    {
        this.packetType = ctx.packetType;
        this.state = ctx.state;
        this.timestamp = ctx.timestamp;
        this.attempt = ctx.attempt;

        switch (packetType)
        {
            case PacketType.PUBLISH:
                this.publish = ctx.publish;
                break;
            case PacketType.SUBSCRIBE:
                this.subscribe = ctx.subscribe;
                break;
            case PacketType.UNSUBSCRIBE:
                this.unsubscribe = ctx.unsubscribe;
                break;
            default:
                assert(0, "Unsupported packet type");
        }

        return this;
    }

    void opAssign(Publish pub)
    {
        this.packetType = PacketType.PUBLISH;
        this.publish = pub;
    }

    void opAssign(Subscribe sub)
    {
        this.packetType = PacketType.SUBSCRIBE;
        this.subscribe = sub;
    }

    void opAssign(Unsubscribe unsub)
    {
        this.packetType = PacketType.UNSUBSCRIBE;
        this.unsubscribe = unsub;
    }
}

/// MQTT session status holder
struct Session
{
    /// Adds packet to Session
    void add(T)(auto ref T packet, PacketState state)
        if (is(T == Publish) || is(T == Subscribe) || is(T == Unsubscribe))
    {
        auto ctx = PacketContext();
        ctx = packet;
        ctx.timestamp = Clock.currTime;
        ctx.state = state;

        if (_packets.full())
            _packets.popBack(); // make place by oldest one removal

        _packets.put(ctx);
    }

    /// Removes the stored PacketContext
    void removeAt(size_t idx)
    {
        _packets.removeAt(_packets[idx..idx+1]);
    }

    /// Finds package context stored in session
    bool canFind(ushort packetId, out PacketContext ctx, out size_t idx, PacketState state = PacketState.any)
    {
        size_t i;
        foreach(ref c; _packets)
        {
            if(c.packetId == packetId && (state == PacketState.any || c.state == state))
            {
                ctx = c;
                idx = i;
                return true;
            }
            ++i;
        }

        return false;
    }

    @property ref PacketContext front()
    {
        return _packets.front();
    }

    void popFront()
    {
        _packets.popFront();
    }

@safe @nogc pure nothrow:

    /// Clears cached messages
    void clear()
    {
        _packets.clear();
    }

    /// Number of packets to process
    @property size_t packetCount() const
    {
        return _packets.length;
    }

private:
    /// Packets to handle
    SessionContainer _packets;
}

/// MQTT Client implementation
class MqttClient
{
    import std.array : Appender;

    this(Settings settings)
    {
        import std.socket : Socket;

        _settings = settings;
        if (_settings.clientId.length == 0) // set clientId if not provided
            _settings.clientId = Socket.hostName;

        _readBuffer.capacity = 4 * 1024;
    }

    final
    {
        /// Connects to the specified broker and sends it the Connect packet
        void connect()
        in { assert(_con is null ? true : !_con.connected); }
        body
        {
            import vibe.core.net: connectTCP;
            import vibe.core.core: runTask;

            //cleanup before reconnects
            _readBuffer.clear();

            _con = connectTCP(_settings.host, _settings.port);
            _listener = runTask(&listener);
            _dispatcher = runTask(&dispatcher);

            version(MqttDebug) logDebug("MQTT Broker Connecting");

            auto con = Connect();
            con.clientIdentifier = _settings.clientId;
            con.flags.cleanSession = true;
            if (_settings.userName.length > 0)
            {
                con.flags.userName = true;
                con.userName = _settings.userName;
                if (_settings.password.length > 0)
                {
                    con.flags.password = true;
                    con.password = _settings.password;
                }
            }

            send(con);
        }

        /// Sends Disconnect packet to the broker and closes the underlying connection
        void disconnect()
        in { assert(!(_con is null)); }
        body
        {
            version(MqttDebug) logDebug("MQTT Disconnectng from Broker");

            if (_con.connected)
            {
                send(Disconnect());
                _con.flush();
                _con.close();

                if(Task.getThis !is _listener)
                    _listener.join;
            }
        }

        /**
         * Return true, if client is in a connected state
         */
        @property bool connected() const
        {
            return _con !is null && _con.connected;
        }

        /**
         * Publishes the message on the specified topic
         *
         * Params:
         *     topic = Topic to send message to
         *     payload = Content of the message
         *     qos = Required QoSLevel to handle message (default is QoSLevel.AtMostOnce)
         *     retain = If true, the server must store the message so that it can be delivered to future subscribers
         *
         */
        void publish(T)(in string topic, in T payload, QoSLevel qos = QoSLevel.QoS0, bool retain = false)
            if (isSomeString!T || (isArray!T && is(ForeachType!T : ubyte)))
        {
            auto pub = Publish();
            pub.header.qos = qos;
            pub.header.retain = retain;
            pub.topic = topic;
            pub.payload = cast(ubyte[]) payload;
            if (qos == QoSLevel.QoS1 || qos == QoSLevel.QoS2)
                pub.packetId = nextPacketId();

            _session.add(pub, qos == QoSLevel.QoS0 ?
                PacketState.queuedQos0 :
                (qos == QoSLevel.QoS1 ? PacketState.queuedQos1 : PacketState.queuedQos2));

            _dispatcher.send(true);
        }

        /**
         * Subscribes to the specified topics
         *
         * Params:
         *      topics = Array of topic filters to subscribe to
         *      qos = This gives the maximum QoS level at which the Server can send Application Messages to the Client.
         *
         */
        void subscribe(string[] topics, QoSLevel qos = QoSLevel.QoS0)
        {
            import std.algorithm : map;
            import std.array : array;

            auto sub = Subscribe();
            sub.packetId = nextPacketId();
            sub.topics = topics.map!(a => Topic(a, qos)).array;

            send(sub);
        }
    }

    void onConnAck(ConnAck packet)
    {
        version(MqttDebug) logDebug("MQTT onConnAck - %s", packet);

        if(packet.returnCode == ConnectReturnCode.ConnectionAccepted)
        {
            version(MqttDebug) logDebug("MQTT Connection accepted");
        }
        else throw new Exception(format("Connection refused: %s", packet.returnCode));
    }

    void onPingResp(PingResp packet)
    {
        version(MqttDebug) logDebug("MQTT onPingResp - %s", packet);
    }

    void onPubAck(PubAck packet)
    {
        version(MqttDebug) logDebug("MQTT onPubAck - %s", packet);

        PacketContext ctx;
        size_t idx;
        if(_session.canFind(packet.packetId, ctx, idx, PacketState.waitForPuback)) // QoS 1
        {
            //treat the PUBLISH Packet as “unacknowledged” until corresponding PUBACK received
            _session.removeAt(idx);
            _dispatcher.send(true);
        }
    }

    void onPubRec(PubRec packet)
    {
        version(MqttDebug) logDebug("MQTT onPubRec - %s", packet);
    }

    void onPubRel(PubRel packet)
    {
        version(MqttDebug) logDebug("MQTT onPubRel - %s", packet);
    }

    void onPubComp(PubComp packet)
    {
        version(MqttDebug) logDebug("MQTT onPubComp - %s", packet);
    }

    void onPublish(Publish packet)
    {
        version(MqttDebug) logDebug("MQTT onPublish - %s", packet);

        //MUST respond with a PUBACK Packet containing the Packet Identifier from the incoming PUBLISH Packet
        if (packet.header.qos == QoSLevel.QoS1)
        {
            auto ack = PubAck();
            ack.packetId = packet.packetId;

            send(ack);
        }
    }

    void onSubAck(SubAck packet)
    {
        version(MqttDebug) logDebug("MQTT onSubAck - %s", packet);
    }

    void onUnsubAck(UnsubAck packet)
    {
        version(MqttDebug) logDebug("MQTT onUnsubAck - %s", packet);
    }

private:
    Settings _settings;
    TCPConnection _con;
    Session _session;
    Task _listener, _dispatcher;
    Serializer!(Appender!(ubyte[])) _sendBuffer;
    FixedRingBuffer!ubyte _readBuffer;
    ubyte[] _packetBuffer;
    ushort _packetId = 1u;

final:

    /// Processes data in read buffer. If whole packet is presented, it delegates it to handler
    void proccessData(in ubyte[] data)
    {
        import mqttd.serialization;
        import std.range;

        version(MqttDebug) logDebug("MQTT IN: %(%.02x %)", data);

        if (_readBuffer.freeSpace < data.length) // ensure all fits to the buffer
            _readBuffer.capacity = _readBuffer.capacity + data.length;
        _readBuffer.put(data);

        if (_readBuffer.length > 0)
        {
            // try read packet header
            FixedHeader header = _readBuffer[0]; // type + flags

            // try read remaining length
            uint pos;
            uint multiplier = 1;
            ubyte digit;
            do
            {
                if (++pos >= _readBuffer.length) return; // not enough data
                digit = _readBuffer[pos];
                header.length += ((digit & 127) * multiplier);
                multiplier *= 128;
                if (multiplier > 128*128*128) throw new PacketFormatException("Malformed remaining length");
            } while ((digit & 128) != 0);

            if (_readBuffer.length < header.length + pos + 1) return; // not enough data

            // we've got the whole packet to handle
            _packetBuffer.length = 1 + pos + header.length; // packet type byte + remaining size bytes + remaining size
            _readBuffer.read(_packetBuffer); // read whole packet from read buffer

            with (PacketType)
            {
                switch (header.type)
                {
                    case CONNACK:
                        onConnAck(_packetBuffer.deserialize!ConnAck());
                        break;
                    case PINGRESP:
                        onPingResp(_packetBuffer.deserialize!PingResp());
                        break;
                    case PUBACK:
                        onPubAck(_packetBuffer.deserialize!PubAck());
                        break;
                    case PUBREC:
                        onPubRec(_packetBuffer.deserialize!PubRec());
                        break;
                    case PUBREL:
                        onPubRel(_packetBuffer.deserialize!PubRel());
                        break;
                    case PUBCOMP:
                        onPubComp(_packetBuffer.deserialize!PubComp());
                        break;
                    case PUBLISH:
                        onPublish(_packetBuffer.deserialize!Publish());
                        break;
                    case SUBACK:
                        onSubAck(_packetBuffer.deserialize!SubAck());
                        break;
                    case UNSUBACK:
                        onUnsubAck(_packetBuffer.deserialize!UnsubAck());
                        break;
                    default:
                        throw new Exception(format("Unexpected packet type '%s'", header.type));
                }
            }
        }
    }

    /// loop to receive packets
    void listener()
    in { assert(_con && _con.connected); }
    body
    {
        import vibe.core.log: logError;

        version(MqttDebug) logDebug("MQTT Entering listening loop");

        auto buffer = new ubyte[4096];

        while (_con.connected)
        {
            auto size = _con.leastSize;
            if (size > 0)
            {
                if (size > buffer.length) size = buffer.length;
                _con.read(buffer[0..size]);
                proccessData(buffer[0..size]);
            }
        }

        version(MqttDebug) logDebug("MQTT Exiting listening loop");
    }

    /// loop to dispatch in session stored packets
    void dispatcher()
    in { assert(_con && _con.connected); }
    body
    {
        import vibe.core.log: logError;
        import vibe.core.core : yield;

        version(MqttDebug) logDebug("MQTT Entering dispatch loop");

        bool exit = false;
        while (_con.connected && !exit)
        {
            // wait for info about change or timeout
            receiveTimeout(_settings.retryDelay.msecs,
                (bool msg) { exit = !msg; });

            if (_session.packetCount > 0)
            {
                //version(MqttDebug) logDebug("MQTT Packets in session: %s", _session.packetCount);
                auto ctx = &_session.front();
                final switch (ctx.state)
                {
                    case PacketState.queuedQos0: // just send it
                        assert(ctx.packetType == PacketType.PUBLISH);
                        send(ctx.publish);
                        _session.popFront(); // remove it from session
                        break;
                    case PacketState.queuedQos1:
                        //treat the Packet as “unacknowledged” until the corresponding PUBACK packet received
                        assert(ctx.packetType == PacketType.PUBLISH);
                        assert(ctx.publish.header.qos == QoSLevel.QoS1);
                        send(ctx.publish);
                        ctx.state = PacketState.waitForPuback; // change to next state
                        break;
                    case PacketState.queuedQos2:
                        break;
                    case PacketState.sendPuback:
                        break;
                    case PacketState.sendPubcomp:
                        break;
                    case PacketState.sendPubrec:
                        break;
                    case PacketState.sendPubrel:
                        break;
                    case PacketState.waitForPuback:
                        break;
                    case PacketState.waitForPubcomp:
                        break;
                    case PacketState.waitForPubrec:
                        break;
                    case PacketState.waitForPubrel:
                        break;
                    case PacketState.waitForSuback:
                        break;
                    case PacketState.waitForUnsuback:
                        break;
                    case PacketState.any:
                        assert(0, "Invalid state");
                }
            }
        }

        version(MqttDebug) logDebug("MQTT Exiting dispatch loop");
    }

    void send(T)(auto ref T msg) if (isMqttPacket!T)
    {
        _sendBuffer.clear(); // clear to write new
        _sendBuffer.serialize(msg);

        if (_con.connected)
        {
            version(MqttDebug) logDebug("MQTT OUT: %(%.02x %)", _sendBuffer.data);
            _con.write(_sendBuffer.data);
        }
    }

    /// Gets next packet id
    @property ushort nextPacketId()
    {
        //TODO: Is this ok or should we check with session packets?
        //packet id can't be 0!
        _packetId = cast(ushort)((_packetId % ushort.max) != 0 ? _packetId + 1 : 1);
        return _packetId;
    }
}

unittest
{
    Session s;

    auto pub = Publish();
    pub.packetId = 0xabcd;
    s.add(pub, PacketState.waitForPuback);

    assert(s.packetCount == 1);

    PacketContext ctx;
    size_t idx;
    assert(s.canFind(0xabcd, ctx, idx));
    assert(idx == 0);
    assert(s.packetCount == 1);

    assert(ctx.packetType == PacketType.PUBLISH);
    assert(ctx.state == PacketState.waitForPuback);
    assert(ctx.attempt == 0);
    assert(ctx.publish != Publish.init);
    assert(ctx.timestamp != SysTime.init);

    s.removeAt(idx);
    assert(s.packetCount == 0);
}
