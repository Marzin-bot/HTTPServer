class_name HTTPServer

extends Reference

##Hyper-text transfer protocol server.
##
##@desc:
##	Hyper-text transfer protocol server.
##	Used to serve files and other data, communicate, process requests from HTTP client (sometimes called "user agents") among other use cases.
##
##@tutorial: tutorial.html
##

const COMPRESSION_NAME_MODE: Dictionary = {
	"gzip": File.COMPRESSION_GZIP,
	"deflate": File.COMPRESSION_DEFLATE,
	"zstd": File.COMPRESSION_ZSTD,
	"fastlz": File.COMPRESSION_FASTLZ
}

const DATETIM_NAME = {
	day = {
		1: "Mon",
		2: "Tue",
		3: "Wed",
		4: "Thu",
		5: "Fri",
		6: "Sat",
		0: "Sun"
	},
	month = {
		1: "Jan",
		2: "Feb",
		3: "Mar",
		4: "Apr",
		5: "May",
		6: "Jun",
		7: "Jul",
		8: "Aug",
		9: "Sep",
		10: "Oct",
		11: "Nov",
		12: "Dec"
	}
}

var http_server = self

class SortPoid:
	static func sort_ascending(a, b) -> bool:
		if a[1] < b[1]:
			return true
		return false


func get_data_priority_header(header) -> Array:
	var result = []
	
	for gf in header.replace(" ", "").split(","):
		var ggffd = gf.split(";q=")
		
		if !ggffd.empty() and ggffd.size() < 3:
			if ggffd.size() == 1:
				ggffd.insert(1, "1")
			elif !ggffd[1].is_valid_float():
				#invalide, on renvoi rien
				return []
		else:
			#invalide, on renvoi rien
			return []
			
		result.push_back(ggffd)
	
	result.sort_custom(SortPoid, "sort_ascending")
	
	return result

#lire le contenue (datas, fichiers ect envoyer pas le client)
class FieldStorage:
	var form_data = {
		"mime": {},
		"champs": {}
	}
	
	func _init(environ) -> void:
		var content_type = environ["CONTENT-TYPE"].split("; ")
		
		form_data["mime"]["type"] = content_type[0]
		form_data["mime"]["charset"] = content_type[1]
		
		if content_type[0] == "application/x-www-form-urlencoded":
			for key_value in environ["CONTENT"].split("&"):
				form_data[key_value.split("=")[0].http_unescape()] = key_value.split("=")[1].http_unescape()
		elif content_type[0] == "multipart/form-data":
			var boundary = content_type[1].replace("boundary=", "")
			
			#Si la fin du message multipart/form-data est valide
			if environ["CONTENT"].ends_with("--" + boundary + "--"):
				var form: PoolStringArray = environ["CONTENT"].split("--" + boundary, false)
				#On supprime le premier élément du tableau car il est vide.
				form.resize(form.size() - 1)
				
				var regex = RegEx.new()
				
				regex.compile("^\\r\\nContent-Disposition: form-data; name=\"([ -~]+)\"\\r\\n\\r\\n([ -~]+)\\r\\n")
				for champ in form:
					var result = regex.search(champ)
					
					if result:
						form_data["champs"][result.strings[1]] = {"content": result.strings[2]}
		else:
			form_data["champs"].append(environ["CONTENT"])

##When set to a valid CryptoKey (along with ssl_certificate) will cause the server to require SSL instead of regular TCP (i.e. the https:// protocol).
var private_key: CryptoKey

##When set to a valid X509Certificate (along with private_key) will cause the server to require SSL instead of regular TCP (i.e. the https:// protocol).
var ssl_certificate: X509Certificate

##When using SSL (see private_key and ssl_certificate), you can set this to a valid X509Certificate to be provided as additional CA chain information during the SSL handshake.
var ca_chain: X509Certificate

var server := TCP_Server.new()
var mutex := Mutex.new()

##If [true] the verboss mode is actived.
var verboss_mode := true

##le nombre max worker
var max_worker := -1

##le nombre max de client que peut gèrer un worker
var max_client_per_worker := -1

var keep_alive := false
var keep_alive_timeout := 5
var accept_compress := false

var ssl := false

# application helloworld par deffaut
func _application(environ):
	return ["200 OK", {"content-type": "text/plain"}, "Hello world".to_utf8()]

var application := funcref(self, "_application")

var application_error

func http_error(environ: Dictionary, status_code: int):
	var http_status
	
	match status_code:
		400:
			http_status = "400 Bad Request"
		403:
			http_status = "403 Forbidden"
		404:
			http_status = "404 Not Found"
		500:
			http_status = "500 Internal Server Error"
		501:
			http_status = "501 Not Implemented"
		503:
			http_status = "503 Service Unavailable"
	
	if application_error:
		var data_vus = application_error.call_func(environ, status_code)
		
		if typeof(data_vus) != TYPE_ARRAY:
			push_error("(HTTPServer) The function assigned to the \"application_error\" variable of the server must return an \"Array\" type object.")
		elif typeof(data_vus[0]) != TYPE_DICTIONARY:
			push_error("(HTTPServer) The object at index 0 of the \"Array\" object returned by the function assigned to the \"application_error\" variable of the server must be of type \"Dictionary\".")
		elif typeof(data_vus[1]) != TYPE_RAW_ARRAY:
			push_error("(HTTPServer) The object at index 1 of the \"Array\" object returned by the function assigned to the \"application_error\" variable of the server must be of type \"PoolByteArray\".")
		else:
			return [http_status] + data_vus
	
	return [http_status, {"content-type": "text/plain"}, http_status.to_utf8()]


##Starts listening on the given port.
func listen(port: int = 80, bind_address: String = "*") -> int:
	var error = server.listen(port)
	
	if verboss_mode:
		if error == OK:
			print("The server HTTP listen the port %s." % [port])
		else:
			print("Listening for the failed server HTTP. (%d)" % [error])
	
	return error


##Stop the server and clear its state.
func stop() -> void:
	server.stop()
	
	if verboss_mode:
		print("The server is no longer listening for connections.")


##Return [true] if the server is currently listening for connections.
func is_listening() -> bool:
	return server.is_listening()

##This needs to be called in order to have any request processed.
var threads = {}

var semaphores = {}

func poll():
	if server.is_connection_available():
		var peer = server.take_connection()
		
		if peer.is_connected_to_host():
			
			#test
			if threads.size() < max_worker or max_worker < 0:
				var thread := Thread.new()
				var semaphore = Semaphore.new()
				
				semaphores[thread] = semaphore
				thread.start(self, "_traitement", {thread=thread, semaphore=semaphore, mutex=mutex})
				
				threads[thread] = []
			
			# on cherche un tread qui a le moins de client a gérer
			var worker_libre = [null, 500]
			for thread in threads.keys():
				if threads[thread].size() < worker_libre[1]:
					worker_libre = [thread, threads[thread].size()]
			
			if threads[worker_libre[0]].size() < max_client_per_worker or max_client_per_worker < 0:
				var settings = {
					peer=peer,
					application=application,
					keep_alive=keep_alive,
					keep_alive_timeout=keep_alive_timeout,
					accept_compress=accept_compress,
					ssl=ssl,
					private_key=private_key,
					ssl_certificate=ssl_certificate,
					ca_chain=ca_chain,
					root=self
				}
				
				threads[worker_libre[0]].append(StreamPeerHTTP.new(settings))
			else:
				print("max_client_per_worker attin!")
			
	#on tue les thread qui non plus de clients a gèrer
	for thread in threads.keys():
		if threads[thread].empty():
			threads.erase(thread)
			semaphores.erase(thread)
			print("thread dead!")
	
	for thread in semaphores.keys():
		semaphores[thread].post()


#test
func _traitement(settings):
	while true:
		settings.semaphore.wait()
		
		for stream_peer_HTTP in threads[settings.thread]:
			if stream_peer_HTTP.process():
				#si le peer demende a mourir
				settings.mutex.lock()
				threads[settings.thread].remove(threads[settings.thread].find(stream_peer_HTTP))
				settings.mutex.unlock()
#fin test


class StreamPeerHTTP:
	signal kill_StreamPeerHTTP(StreamPeerHTTP)
	
	var settings
	var peer
	var timeout
	var http_response := ""
	var data_vus: Array
	var application_error
	var application
	var ssl
	
	var verboss_mode = true
	
	var header = null
	var numb := 0
	
	func _init(settings_parameter):
		settings = settings_parameter
		application = settings.application
		
		peer = settings.peer
		ssl = settings.ssl
		
		if ssl:
			peer = StreamPeerSSL.new()
			
			peer.accept_stream(settings.peer, settings.private_key, settings.ssl_certificate, settings.ca_chain)
		
		timeout = settings.keep_alive_timeout + OS.get_system_time_secs()
	
	func http_error(environ: Dictionary, status_code: int):
		var http_status
		
		match status_code:
			400:
				http_status = "400 Bad Request"
			403:
				http_status = "403 Forbidden"
			404:
				http_status = "404 Not Found"
			500:
				http_status = "500 Internal Server Error"
			501:
				http_status = "501 Not Implemented"
			503:
				http_status = "503 Service Unavailable"
		
		if application_error:
			var data_vus = application_error.call_func(environ, status_code)
			
			if typeof(data_vus) != TYPE_ARRAY:
				push_error("(HTTPServer) The function assigned to the \"application_error\" variable of the server must return an \"Array\" type object.")
			elif typeof(data_vus[0]) != TYPE_DICTIONARY:
				push_error("(HTTPServer) The object at index 0 of the \"Array\" object returned by the function assigned to the \"application_error\" variable of the server must be of type \"Dictionary\".")
			elif typeof(data_vus[1]) != TYPE_RAW_ARRAY:
				push_error("(HTTPServer) The object at index 1 of the \"Array\" object returned by the function assigned to the \"application_error\" variable of the server must be of type \"PoolByteArray\".")
			else:
				return [http_status] + data_vus
		
		return [http_status, {"content-type": "text/plain"}, http_status.to_utf8()]
		
	func get_data_priority_header(header) -> Array:
		var result = []
		
		for gf in header.replace(" ", "").split(","):
			var ggffd = gf.split(";q=")
			
			if !ggffd.empty() and ggffd.size() < 3:
				if ggffd.size() == 1:
					ggffd.insert(1, "1")
				elif !ggffd[1].is_valid_float():
					#invalide, on renvoi rien
					return []
			else:
				#invalide, on renvoi rien
				return []
				
			result.push_back(ggffd)
		
		result.sort_custom(SortPoid, "sort_ascending")
		
		return result
	
	static func dictionary_merge(target: Dictionary, patch: Dictionary):
		for key in patch:
			target[key] = patch[key]
	
	func process():
		if((settings.keep_alive and OS.get_system_time_secs() < timeout) or !settings.keep_alive or header) and settings.peer.is_connected_to_host():
			if peer.get_status() == StreamPeerSSL.STATUS_CONNECTED or peer.get_status() == StreamPeerSSL.STATUS_HANDSHAKING:
				if !header:
					if ssl:
						peer.poll()
					
					#on récup la requet du client
					var response = peer.get_partial_data(peer.get_available_bytes())
					
					#si ya pas d'erreur
					if response[0] == OK:
						http_response += response[1].get_string_from_utf8()
					else:
						print("erreur 500")
						if ssl:
							peer.disconnect_from_stream()
						else:
							peer.disconnect_from_host()
						print("http peer dead: ", numb)
						return true
					
					if http_response.ends_with("\r\n"):
						numb += 1
						if settings.keep_alive:
							timeout = settings.keep_alive_timeout + OS.get_system_time_secs()
						
						var headers_dictionary = {
							"accept-ranges": "bytes",
							"server": "Godot Engine",
						}
						
						var environ = {
							"REMOTE_ADDR": peer.get_connected_host(),
							"REMOTE_PORT": peer.get_connected_port()
						}
						
						#on valide la request du client
						var regex = RegEx.new()
						
						regex.compile("^(GET|HEAD|POST|OPTIONS|CONNECT|TRACE|PUT|PATCH|DELETE) (/(?:\\S[^#\\s\\?\\x80-\\xFF]*)?)(\\?[^:#\\s\\x80-\\xFF]*)? HTTP/(\\d+)(\\.\\d+)?\\r\\n((?:(?:[ -~])+\\r\\n)+)\\r\\n(?:((?:.|\\s)*)\\r\\n|)")
						
						var result = regex.search(http_response)
						
						if result:
							environ["REQUEST_METHOD"] = result.strings[1]
							environ["PATH"] = result.strings[2].http_unescape()
							environ["QUERY_STRING"] = result.strings[3].http_unescape()
							environ["SERVER_PROTOCOL"] = result.strings[4] + result.strings[5]
							environ["CONTENT"] = result.strings[7]
							
							regex.compile("^(\\S+): ((?:\\S+| +)+)$")
							
							var headers = result.strings[6].split("\r\n")
							headers.remove(headers.size() - 1)
							
							for header in headers:
								result = regex.search(header)
								
								if result:
									environ[result.strings[1].to_upper()] = result.strings[2]
								else:
									environ = {}
									break
							
							if environ["SERVER_PROTOCOL"] == "HTTP/1.1" and !"HOST" in environ:
								environ = {}
						else:
							print("erreur, 400")
						
						if response[0] == OK:
							if environ:
								data_vus = application.call_funcv([environ])
								
								#on pence a vérif les valeur retourner parle la fonction affecter la la variable aplication du server
								if typeof(data_vus) != TYPE_ARRAY:
									push_error("(HTTPServer) The function assigned to the \"application\" variable of the server must return an \"Array\" type object.")
									data_vus = http_error(environ, 500)
								elif typeof(data_vus[0]) != TYPE_STRING:
									push_error("(HTTPServer) The object at index 0 of the \"Array\" object returned by the function assigned to the \"application\" variable of the server must be of type \"String\".")
									data_vus = http_error(environ, 500)
								elif typeof(data_vus[1]) != TYPE_DICTIONARY:
									push_error("(HTTPServer) The object at index 1 of the \"Array\" object returned by the function assigned to the \"application\" variable of the server must be of type \"Dictionary\".")
									data_vus = http_error(environ, 500)
								elif typeof(data_vus[2]) != TYPE_RAW_ARRAY:
									push_error("(HTTPServer) The object at index 2 of the \"Array\" object returned by the function assigned to the \"application\" variable of the server must be of type \"PoolByteArray\".")
									data_vus = http_error(environ, 500)
									
								if "RANGE" in environ and environ["REQUEST_METHOD"] == "GET":
									var regeTTTTx = RegEx.new()
									
									regeTTTTx.compile("^bytes=(\\d+)-(\\d*)")
									var resultTTT = regeTTTTx.search(environ["RANGE"])
									
									if resultTTT:
										data_vus[0] = "206 Partial Content"
										
										var to = resultTTT.strings[2]
										if !to:
											to = data_vus[2].size() - 1
										
										headers_dictionary["content-range"] = "bytes %s-%d/%d" % [resultTTT.strings[1], to, data_vus[2].size()]
										data_vus[2] = data_vus[2].subarray(resultTTT.strings[1], to)
									else:
										data_vus = http_error(environ, 400)
								
								if "ACCEPT-ENCODING" in environ and settings.accept_compress:
									for code in get_data_priority_header(environ["ACCEPT-ENCODING"]):
										if code[0] in COMPRESSION_NAME_MODE:
											data_vus[2] = data_vus[2].compress(COMPRESSION_NAME_MODE[code[0]])
											
											if "RANGE" in environ and environ["REQUEST_METHOD"] == "GET":
												headers_dictionary["transfert-encodage"] = code[0]
											else:
												headers_dictionary["content-encoding"] = code[0]
											
											break
										elif code[0] == "identity":
											if "RANGE" in environ and environ["REQUEST_METHOD"] == "GET":
												headers_dictionary["transfert-encodage"] = "identity"
											else:
												headers_dictionary["content-encoding"] = "identity"
											
											break
							else:
								data_vus = http_error(environ, 400)
						else:
							data_vus = http_error(environ, 500)
						
						dictionary_merge(headers_dictionary, data_vus[1])
						
						var datetime = OS.get_datetime(true)
						
						var datetime_datas = [
							DATETIM_NAME.day[datetime.weekday],
							str(datetime.day).pad_zeros(2),
							DATETIM_NAME.month[datetime.month],
							datetime.year,
							str(datetime.hour).pad_zeros(2),
							str(datetime.minute).pad_zeros(2),
							str(datetime.second).pad_zeros(2)
						]
						
						headers_dictionary["date"] = "%s, %s %s %d %s:%s:%s GMT" % datetime_datas
						
						headers_dictionary["content-length"] = str(data_vus[2].size())
						
						if settings.keep_alive:
							headers_dictionary["connection"] = "Keep-Alive"
							headers_dictionary["keep-alive"] = "timeout=" + str(settings.keep_alive_timeout)
						
						header = "HTTP/1.1 %s\r\n" % [data_vus[0]]
						
						for field_name in headers_dictionary.keys():
							header = header + field_name + ": " + headers_dictionary[field_name] + "\r\n"
						
						header = (header + "\r\n").to_utf8()
						
						if environ["REQUEST_METHOD"] != "HEAD":
							header.append_array(data_vus[2])
						
						if verboss_mode:
							prints(environ["REMOTE_ADDR"] + ":" + String(environ["REMOTE_PORT"]), environ["PATH"], environ["REQUEST_METHOD"], data_vus[0])
				
				if header:
					var error_and_cursor_responce = peer.put_partial_data(header)
					
					if error_and_cursor_responce[0]:
						print("error 500, le client a sans dout du se déconnecter en cour de rout")
						
						header = null
					else:
						#on tronque la parti servi par le serveur pour garder que la parti non servi qui plustard devra être servi par le serveur
						header = header.subarray(error_and_cursor_responce[1], -1)
						
					#quand la totalité de la réponce a été servi
					if !header:
						data_vus = []
						print("complet")
						http_response = ""
						if !settings.keep_alive:
							if ssl:
								peer.disconnect_from_stream()
							else:
								peer.disconnect_from_host()
							
							print("ssss")
							print("http peer dead: ", numb)
							return true
			else:
				if ssl:
					peer.disconnect_from_stream()
				else:
					peer.disconnect_from_host()
				
				print("oooo")
				print("http peer dead: ", numb)
				return true
		else:
			if ssl:
				peer.disconnect_from_stream()
			else:
				peer.disconnect_from_host()
			
			print("rrrrrr")
			print("http peer dead: ", numb)
			return true
