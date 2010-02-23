require 'rubygems'
require 'json'
require 'restclient'
require 'ostruct'
require 'rush'
require 'ohai'
require 'erb'

## IDEAS

## firewall until ready
## ruby 1.9 compatibility

class Kuzushi
	def initialize(url)
		@base_url = File.dirname(url)
		@name = File.basename(url)
		@config_names = []
		@configs = []
		@packages = []
		@tasks = []
		load_config_stack(@name)
		@config = @configs.reverse.inject({}) { |i,c| i.merge(c) }
	end

	def init
		@init = true
		start
	end

	def start
		process_stack
		puts "----"
		@tasks.each do |t|
			puts "TASK: #{t[:description]}"
			t[:blk].call
		end
		puts "----"
	end

	protected

	def system
		ohai = Ohai::System.new
		ohai.all_plugins
		ohai
	end

	def load_config_stack(name)
		@config_names << name
		@configs << JSON.parse(RestClient.get("#{@base_url}/#{name}"))
		if import = @configs.last["import"]
			load_config_stack(import)
		end
	end

	def process_stack
		script get("before")

		process :packages
		process :local_packages
		process :gems
		process :volumes
		process :files
		process :users

		script get("after")
		script get("init") if init?
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
				script item["init"] if init?
			end
		end
	end

	def process_packages
		@packages = get_array("packages")
		task "install packages" do
			shell "apt-get update && apt-get upgrade -y"
			shell "apt-get install -y #{@packages.join(" ")}" if @packages.empty?
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
		handle_tmpfs  v if v.media == "tmpfs"
		handle_ebs    v if v.media == "ebs"
		handle_raid   v if v.media == "raid"
		set_readahead v if v.readahead
		set_scheduler v if v.scheduler
		handle_format v if v.format
		handle_mount  v if v.mount
	end

	def handle_ebs(v)
		task "wait for volume #{v.device}" do
			wait_for_volume v.device
		end
	end

	def handle_raid(r)
		task "create raid #{r.device}", :init => true do
			shell "mdadm --create #{r.device} -n #{r.drives.size} -l #{r.level} -c #{r.chunksize || 64} #{r.drives.join(" ")}"
		end
		task "assemble raid #{r.device}" do  ## assemble fails a lot with device busy - is udev to blame :(
			if not dev_exists? r.device
				shell "service stop udev"
				shell "mdadm --assemble #{r.device} #{r.drives.join(" ")}"
				shell "service start udev"
			end
		end
		add_package "mdadm"
	end

	def mount_options(m)
		o = []
		o << m.options if m.options
		o << "size=#{m.size}M" if m.size and m.media == "tmpfs"
		o << "mode=#{m.mode}" if m.mode
		o << "noatime" if o.empty?
		o.join(",")
	end

	def handle_tmpfs(m)
		task "mount #{m.mount}" do
			shell "mkdir -p #{m.mount} && mount -o #{mount_options(m)} -t tmpfs tmpfs #{m.mount}" unless mounted?(m.mount)
		end
	end

	def handle_mount(m)
		task "mount #{m.mount}" do
			shell "mkdir -p #{m.mount} && mount -o #{mount_options(m)} #{m.device} #{m.mount}" unless mounted?(m.mount)
		end
	end

	def system_arch
		system.kernel["machine"]
	end

	def mounted?(mount)
		## cant use ohai here b/c it mashes drives together with none or tmpfs devices
		mount = mount.chop if mount =~ /\/$/
		!!(File.read("/proc/mounts") =~ / #{mount} /)
	end

	def package_arch
		`dpkg --print-architecture`.chomp
	end

	def process_files(f)
		fetch("/templates/#{f.template}") do |file|
			task "setting up #{f.file}" do
				@system = system
				t = ERB.new File.read(file), 0, '<>'
				File.open(f.file,"w") { |f| f.write(t.result(binding)) }
			end
		end
	end

	def process_users(user)
		(user.authorized_keys || []).each do |key|
			task "add authorized_key for user #{user.name}" do
				shell "su - #{user.name} -c 'mkdir -p .ssh; echo \"#{key}\" >> .ssh/authorized_keys; chmod -R 0600 .ssh'"
			end
		end
	end

	def set_readahead(v)
		task "set readahead for #{v.device}" do
			shell "blockdev --setra #{v.readahead} #{v.device}"
		end
	end

	def set_scheduler(v)
		task "set scheduler for #{v.device}" do
			shell "echo #{v.scheduler} > /sys/block/#{File.basename(v.device)}/queue/scheduler"
		end
	end

	def handle_format(v)
		task "formatting #{v.device}", :init => true do
			label = "-L " + v.label rescue ""
			shell "mkfs.#{v.format} #{label} #{v.device}"
		end
		add_package "xfsprogs" if v.format == "xfs"
	end

	def add_package(p)
		@packages << p unless @packages.include? p
	end

	def package(p, &block)
		fetch("/packages/#{p}_#{package_arch}.deb") do |file|
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
			f.chmod(0700)
		end if content
		block.call(file) if block
		file
	end

	def fetch(file, &block)
		names = @config_names.clone
		begin
			## its important that we try each name for the script - allows for polymorphic scripts
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
		@config[key.to_s]
	end

	def get_array(key)
		[ get(key) || [] ].flatten
	end

	def wait_for_volume(vol)
		## Maybe use ohai here instead -- FIXME
		until dev_exists? vol do
			puts "waiting for volume #{vol}"
			sleep 2
		end
	end

	def shell(cmd)
		puts "# #{cmd}"
		puts Rush.bash cmd
	end

	def init?
		@init ||= false
	end

	def task(description, options = {}, &blk)
		return if options[:init] and not init?
		@tasks << { :description => description, :blk => blk }
	end

	def dev_exists?(dev)
		File.exists?("/sys/block/#{File.basename(dev)}")
	end
end
