import mqttd;

shared static this()
{
	import vibe.core.core : sleep, runTask;
	import vibe.core.log;
	import core.time;
	
	auto settings = Settings();
	settings.clientId = "publisher";
	
	auto mqtt = new MqttClient(settings);
	mqtt.connect();
	
	auto publisher = runTask(() 
		{
			mqtt.disconnect();
			logDiagnostic("Disconnected");
		});
}
