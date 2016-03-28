require 'websocket-eventmachine-client'
require 'json'
require 'jsondiff'
require 'hana'

class SeapigServer

	attr_reader :socket
	
	def initialize(uri, options={})
		@connected = false
		@uri = uri
		@options = options
		@slave_objects = {}
		@master_objects = {}
		
		connect
	end


	def connect

		if @socket
			@socket.onclose {}
			@socket.close
		end

		@timeout_timer ||= EM.add_periodic_timer(10) {
			next if not @socket
			next if Time.new.to_f - @last_communication_at < 20
			puts "Seapig ping timeout, reconnecting"
			connect
		} 
		
		@connected = false

		@last_communication_at = Time.new.to_f
		@socket = WebSocket::EventMachine::Client.connect(uri: @uri)

		@socket.onopen {
			@connected = true
			@socket.send JSON.dump(action: 'client-options-set', options: @options)
			@slave_objects.each_pair { |object_id, object|
				@socket.send JSON.dump(action: 'object-consumer-register', id: object_id, latest_known_version: object.version)
			}
			@master_objects.each_pair { |object_id, object|
				@socket.send JSON.dump(action: 'object-producer-register', pattern: object_id)
			}
			@last_communication_at = Time.new.to_f
		}
		
		@socket.onmessage { |message|
			message = JSON.load message
			#p message['action'], message['id'], message['patch']
			case message['action']
			when 'object-update'
				@slave_objects.values.each { |object|
					object.patch(message) if object.matches?(message['id'])
				}
			when 'object-destroy'
				@slave_objects.values.each { |object|
					object.destroy(message) if object.matches?(message['id'])
				}
			when 'object-produce'
				handler = @master_objects.keys.find { |key| key.include?('*') and (message['id'] =~ Regexp.new(Regexp.escape(key).gsub('\*','.*?'))) or (message['id'] == key) }
				@master_objects[handler].onproduce_proc.call(message['id']) if @master_objects[handler].onproduce_proc
				@master_objects[handler].upload(0,{},message['id']) if @master_objects[handler]
			else
				p :wtf, message
			end
			@last_communication_at = Time.new.to_f
		}
		
		@socket.onclose { |code, reason|
			puts 'Seapig connection died unexpectedly (code:'+code.inspect+', reason:'+reason.inspect+'), reconnecting in 1s'
			sleep 1
			connect
		}

		@socket.onerror { |error|
			puts 'Seapig error: '+error.inspect
		}

		@socket.onping {
			@last_communication_at = Time.new.to_f
		}

	end
	

	
	def disconnect(detach_fd = false)
		@connected = false
		if @timeout_timer
			@timeout_timer.cancel
			@timeout_timer = nil
		end
		if @socket
			@socket.onclose {}
			if detach_fd
				IO.new(@socket.detach).close
			else
				@socket.close
			end
			@socket = nil
		end
	end


	def detach_fd
		disconnect(true)
	end
	
	
	def slave(object_id)
		object = if object_id.include?('*') then SeapigWildcardObject.new(self, object_id) else SeapigObject.new(self, object_id) end
		@socket.send JSON.dump(action: 'object-consumer-register', id: object_id, latest_known_version: object.version) if @connected
		@slave_objects[object_id] = object
	end


	def master(object_id)
		object = SeapigObject.new(self, object_id)
		object.version = Time.new.to_f
		@socket.send JSON.dump(action: 'object-producer-register', pattern: object_id) if @connected
		@master_objects[object_id] = object
	end
end


class SeapigObject < Hash

	attr_accessor :version, :object_id, :valid, :onproduce_proc, :stall, :parent, :destroyed


	def matches?(id)
		id =~ Regexp.new(Regexp.escape(@object_id).gsub('\*','.*?'))
	end


	def initialize(server, object_id, parent = nil)
		@server = server
		@object_id = object_id
		@version = 0
		@onchange_proc = nil
		@onproduce_proc = nil
		@valid = false
		@shadow = JSON.load(JSON.dump(self))
		@stall = false
		@parent = parent
		@destroyed = false
	end

	
	def onchange(&block)
		@onchange_proc = block
	end


	def onproduce(&block)
		@onproduce_proc = block
	end

	
	def patch(message)
		if not message['old_version']
			self.clear
		elsif message['old_version'] == 0
			self.clear
		elsif not @version == message['old_version']
			p @version, message
			puts "Seapig lost some updates, this should never happen"
			exit 2
		end		
		Hana::Patch.new(message['patch']).apply(self)
		@version = message['new_version']
		@valid = true
		@onchange_proc.call(self) if @onchange_proc
	end


	def set(data, version)
		if data
			@stall = false
			self.clear
			self.merge!(data)
			@shadow = sanitized
		else
			@stall = true
		end
		@version = version
	end

	
	def changed
		old_version = @version
		old_object = @shadow
		@version += 1
		@shadow = sanitized
		upload(old_version, old_object, @object_id)	
	end


	def sanitized
		JSON.load(JSON.dump(self))
	end


	def upload(old_version, old_object, object_id)
		message = {
			id: object_id,
			action: 'object-patch',
			old_version: old_version,
			new_version: @version,
		}
		if old_version == 0 or @stall
			message.merge!(value: (if @stall then false else @shadow end))
		else
			message.merge!(patch: JsonDiff.generate(old_object, @shadow))
		end
		@server.socket.send JSON.dump(message)
	end
	
	

end



class SeapigWildcardObject < SeapigObject


	def patch(message)
		self[message['id']] ||= SeapigObject.new(@server, message['id'], self)
		self[message['id']].patch(message)
#		puts JSON.dump(self)
		@onchange_proc.call(self[message['id']]) if @onchange_proc
	end


	def destroy(message)
		if destroyed = self.delete(message['id'])
			destroyed.destroyed = true
			@onchange_proc.call(destroyed) if @onchange_proc
		end
	end

end


