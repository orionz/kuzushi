require 'rubygems'
require 'json'
require 'restclient'
require 'ostruct'
require 'ohai'
require 'erb'

## IDEAS

## firewall until ready
## ruby 1.9 compatibility
## nested configs
## user configs

class Kuzushi
	attr_accessor :config, :config_names

	def initialize(url)
		@base_url = File.dirname(url)
		@name = File.basename(url)
		@config_names = []
		@configs = []
		@packages = []
		@tasks = []
	end

	def init
		@init = true
		start
	end

	def start
		load_config_stack(@name)
		process_stack
		log "----"
		@tasks.each do |t|
			log "TASK: #{t[:description]}"
			t[:blk].call
		end
		log "----"
	end

	protected

	def system
		ohai = Ohai::System.new
		ohai.all_plugins
		ohai
	end

	def http_get(url)
		RestClient.get(url)
	end

	def load_config_stack(name)
		@config_names << name
		@configs << JSON.parse(http_get("#{@base_url}/#{name}"))
		if import = @configs.last["import"]
			load_config_stack(import)
		else
			@config = @configs.reverse.inject({}) { |i,c| i.merge(c) }
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
		process :crontab

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
#			shell "apt-get update"
			shell "apt-get install -y #{@packages.join(" ")}" unless @packages.empty?
#			@packages.each do |pkg|
#				shell "apt-get install -y #{pkg}"
#			end
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

	def handle_mount(m)
		task "mount #{m.mount}" do
			unless mounted?(m.mount)
				shell "mv #{m.mount} #{m.mout}.old" if File.exists?(m.mount)
				shell "mkdir -p #{m.mount} && mount -o #{mount_options(m)} -t #{m.format || m.media} #{m.device || m.media} #{m.mount}"
				shell "chown -R #{m.user}:#{m.group} #{m.mount}" if m.user or m.group
			end
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

	def erb(data)
			@system = system
			ERB.new(data, 0, '<>').result(binding)
	end

	def process_files(f)
		file(f) do |tmp|
			task "write #{f.file}" do
				cp_file(tmp, f.file)
			end
		end
	end

	def process_crontab(cron)
		user = cron.user || "root"
		file(cron) do |tmp|
			task "process crontab for #{user}" do
				shell "crontab -u #{user} #{tmp}"
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
		return if v.format == "tmpfs"
		task "formatting #{v.device}", :init => true do
			label = "-L " + v.label rescue ""
			shell "mkfs.#{v.format} #{label} #{v.device}" unless v.mount && mounted?(v.mount)
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


	def script(scripts)
		to_array(scripts).each do |s|
			if s =~ /^#!/
				inline_script(s)
			else
				external_script(s)
			end
		end
	end

	def inline_script(script)
		tmpfile(script) do |tmp|
			task "run inline script" do
				shell "#{tmp}"
			end
		end
	end

	def external_script(script)
		fetch("/scripts/#{script}") do |file|
			task "run script #{script}" do
				shell "#{file}"
			end
		end
	end

	def tmpfile(content, file = "tmp_#{rand(1_000_000_000)}", &block)
		path = "/tmp/kuzushi/#{File.basename(file)}"
		put_file(content, path)
		block.call(path) if block
		path
	end

	def file(f, &blk)
		## no magic here - move along
		fetch("/templates/#{f.template}", lambda { |data| erb data  }, &blk) if f.template
		fetch("/files/#{f.source || File.basename(f.file)}", &blk) unless f.template
	end

	def fetch(file, filter = lambda { |d| d }, &block)
		names = config_names.clone
		begin
			## its important that we try each name for the script - allows for polymorphic scripts
			tmpfile(filter.call(http_get("#{@base_url}/#{names.first}#{file}")), file) do |tmp|
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
		puts exception.message
	end

	def get(key)
		config[key.to_s]
	end

	def get_array(key)
		to_array( get(key) )
	end

	def to_array(value)
		[ value || [] ].flatten
	end

	def wait_for_volume(vol)
		## Maybe use ohai here instead -- FIXME
		until dev_exists? vol do
			log "waiting for volume #{vol}"
			sleep 2
		end
	end

	def shell(cmd)
		log "# #{cmd}"
		Kernel.system cmd ## FIXME - need to handle/report exceptions here
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

	def cp_file(src, dest)
		FileUtils.mkdir_p(File.dirname(dest))
		FileUtils.cp(src, dest)
	end

	def put_file(data, dest)
		FileUtils.mkdir_p(File.dirname(dest))
		File.open(dest,"w") do |f|
			f.write(data)
			f.chmod(0700)
		end
	end

	def log(message)
		puts message
	end
end
