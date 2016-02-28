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

		@socket = WebSocket::EventMachine::Client.connect(uri: uri)

		@socket.onopen {
			@connected = true
			@socket.send JSON.dump(action: 'client-options-set', options: @options)
			@slave_objects.each_pair { |object_id, object|
				@socket.send JSON.dump(action: 'object-consumer-register', id: object_id, latest_known_version: object.version)
			}
			@master_objects.each_pair { |object_id, object|
				@socket.send JSON.dump(action: 'object-producer-register', pattern: object_id)
				object.upload(0, {})
			}
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
				@master_objects[message['id']].upload(0,{}) if @master_objects[message['id']]
			else
				p :wtf, message
			end
		}
		
		@socket.onclose { |code, reason|
			if @connected
				puts 'Seapig connection died, quitting'
				EM.stop
			end
		}
	end


	def disconnect
		@connected = false
		@socket.close
	end


	def detach_fd
		@connected = false
		IO.new(@socket.detach).close
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

	attr_accessor :version, :object_id, :valid


	def matches?(id)
		id =~ Regexp.new(Regexp.escape(@object_id).gsub('\*','.*?'))
	end


	def initialize(server, object_id)
		@server = server
		@object_id = object_id
		@version = 0
		@onchange = nil
		@valid = false
		@shadow = JSON.load(JSON.dump(self))
	end

	
	def onchange(&block)
		@onchange = block
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
		@onchange.call(self) if @onchange
	end


	def changed
		old_version = @version
		@version += 1
		upload(old_version, @shadow)
		@shadow = sanitized
	end


	def sanitized
		JSON.load(JSON.dump(self))
	end


	def upload(old_version, old_object)
		message = {
			id: @object_id,
			action: 'object-patch',
			old_version: old_version,
			new_version: @version,
			patch: JsonDiff.generate(old_object, self.sanitized)
		}
		@server.socket.send JSON.dump(message)
	end
	
	

end



class SeapigWildcardObject < SeapigObject


	def patch(message)
		self[message['id']] ||= SeapigObject.new(@server, message['id'])
		self[message['id']].patch(message)
#		puts JSON.dump(self)
		@onchange.call(self) if @onchange
	end


	def destroy(message)
		self.delete(message['id'])
		@onchange.call(self) if @onchange
	end

end


