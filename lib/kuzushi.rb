require 'rubygems'
require 'json'
require 'restclient'
require 'ostruct'

class Kuzushi
	def initialize(url)
		@base_url = File.dirname(url)
		@name = File.basename(url)
		@config_names = []
		@config = []
		@packages = []
		@tasks = []
		load_config_stack(@name)
		process_stack
	end

	def load_config_stack(name)
		@config_names << name
		@config << JSON.parse(RestClient.get("#{@base_url}/#{name}"))
		if import = @config.last["import"]
			load_config_stack(import)
		end
	end

	def process_stack
		script get("before")

		process :packages
		process :local_packages
		process :gems
		process :volumes
		process :raids
		process :mounts
		process :files
		process :users

		script get("after")
	end

	## magic goes here
	def process(type)
		## if the file takes no args - just call it once
		if method("process_#{type}").arity == 0
			send("process_#{type}")
		else
		## else call it once per item
			get_array(type).each do |item|
				script item["before"]
				if item.is_a? Hash
					send("process_#{type}", OpenStruct.new(item))
				else
					send("process_#{type}", item)
				end
				script item["after"]
			end
		end
	end

	def process_packages
		@packages = get_array("packages")
		task "install packages" do
			shell "apt-get update && apt-get upgrade -y && apt-get install -y #{@packages.join(" ")}", "DEBIAN_FRONTEND" => "noninteractive", "DEBIAN_PRIORITY" => "critical"
		end
	end

	def process_local_packages(p)
		package(p) do |file|
			task "install local package #{p}" do
				shell "dpkg -i #{file}"
			end
		end
	end

	def process_gems(gem)
		task "install gem #{gem}" do
			shell "gem install #{gem} --no-rdoc --no-ri"
		end
	end

	def process_volumes(v)
		task "wait for volume #{v.device}" do
			wait_for_volume v.device
		end
		set_scheduler(v)
		check_format(v)
	end

	def process_raids(r)
		task "assemble raid #{r.device}" do
			shell "mdadm --assemble #{r.device} #{r.drives.join(" ")}"
		end
		set_scheduler r
		check_format r
		add_package "mdadm"
	end

	def process_mounts(m)
		task "mount #{m.label}" do
			shell "mount -o #{m.options} -L #{m.label} #{m.label}"
		end
	end

	def process_files(f)
		fetch("/templates/#{f.template}") do |file|
			task "setting up #{f.file}" do
				shell "erb #{f.template} > #{f.file}" ## FIXME
			end
		end
	end

	def process_users(user)
		(user.authorized_keys || []).each do |key|
			task "add authorized_key for user #{user.name}" do
				shell "su - #{user.name} -c 'mkdir -p .ssh; echo \"#{key}\" >> .ssh/authorized_keys; chmod -R 600 .ssh'"
			end
		end 
	end

	def set_scheduler(v)
		if v.scheduler
			task "set scheduler for #{v.device}" do
				shell "echo #{v.scheduler} > /sys/block/#{File.basename(v.device)}/queue/scheduler"
			end
		end
	end

	def check_format(v)
		add_package "xfsprogs" if v.format == "xfs"
	end

	def add_package(p)
		@packages << p unless @packages.include? p
	end

	def package(p, &block)
		fetch("/packages/#{p}_i386.deb") do |file|
			block.call(file)
		end
	end

	def inline_script(script)
		tmpfile(script) do |tmp|
			task "run inline script" do
				shell "#{tmp}"
			end
		end
	end

	def script(script)
		return if script.nil?
		return inline_script(script) if script =~ /^#!/

		fetch("/scripts/#{script}") do |file|
			task "run script #{script}" do
				shell "#{file}"
			end
		end
	end

	def tmpfile(content, file = "tmp_#{rand(1_000_000_000)}", &block)
		tmp_dir = "/tmp/kuzushi"
		Dir.mkdir(tmp_dir) unless File.exists?(tmp_dir)
		file = "#{tmp_dir}/#{File.basename(file)}"
		File.open(file,"w") do |f|
			f.write(content)
			f.chmod(700)
		end if content
		block.call(file) if block
		file
	end

	def fetch(file, &block)
		names = @config_names.clone
		begin
			tmpfile RestClient.get("#{@base_url}/#{names.first}#{file}"), file do |tmp|
				block.call(tmp)
			end
		rescue RestClient::ResourceNotFound
			names.shift
			retry unless names.empty?
			error("file not found: #{file}")
		rescue Object => e
			error("error fetching file: #{names.first}/#{file}", e)
		end
	end

	def error(message, exception = nil)
		puts "ERROR :#{message}"
	end

	def get(key)
		@config.map { |c| c[key.to_s] }.detect { |v| v }
	end

	def get_array(key)
		d = get(key)
		return []  if d.nil?
		return d   if d.is_a?(Array)
		return [d]
	end

	def wait_for_volume(vol)
		puts "waiting for volume #{vol}"
	end

	def start
		puts "----"
		@tasks.each do |t|
			puts "TASK: #{t[:description]}"
			t[:blk].call
		end
		puts "----"
	end

	def shell(cmd, env = {})
		puts "  SHELL: #{cmd}"
	end

	def task(description, &blk)
		@tasks << { :description => description, :blk => blk }
	end

	def path
		Dir["**/config.json"]
	end
end
