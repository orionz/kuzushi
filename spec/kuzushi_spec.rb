require File.dirname(__FILE__) + '/base'

describe Kuzushi do
	before do
		@url = "http://myurl/foo"
		@kuzushi = Kuzushi.new(@url)
		@kuzushi.stubs(:log) ## dont want to see the output
		@kuzushi.stubs(:config_names).returns(["foo"])
		@kuzushi.stubs(:load_config_stack)
	end
	
	it "processes a simple file" do
		@kuzushi.stubs(:config).returns( {
			"files" => [ {
				"file" => "/var/lib/zing.conf"
		} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/files/zing.conf").returns( "123" )
		@kuzushi.expects(:put_file).with("123", "/tmp/kuzushi/zing.conf")
		@kuzushi.expects(:cp_file).with("/tmp/kuzushi/zing.conf", "/var/lib/zing.conf")
		should.not.raise { @kuzushi.start }
	end

	it "processes a simple file with a different source" do
		@kuzushi.stubs(:config).returns( {
			"files" => [ {
				"file" => "/var/lib/zing.conf",
				"source" => "zing-8.2"
			} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/files/zing-8.2").returns( "123" )
		@kuzushi.expects(:put_file).with("123", "/tmp/kuzushi/zing-8.2")
		@kuzushi.expects(:cp_file).with("/tmp/kuzushi/zing-8.2", "/var/lib/zing.conf")
		should.not.raise { @kuzushi.start }
	end

	it "processes a file from an erb template" do
		@kuzushi.stubs(:config).returns( {
			"files" => [ {
				"file" => "/var/lib/zing.conf",
				"template" => "zing-8.2.erb"
			} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/templates/zing-8.2.erb").returns( "I love <%= ['e','r','b'].join('') %>" )
		@kuzushi.expects(:put_file).with("I love erb", "/tmp/kuzushi/zing-8.2.erb")
		@kuzushi.expects(:cp_file).with("/tmp/kuzushi/zing-8.2.erb", "/var/lib/zing.conf")
		should.not.raise { @kuzushi.start }
	end

	it "can handle a basic crontab with a specified file" do
		@kuzushi.stubs(:config).returns( {
			"crontab" => [ {
				"file" => "mycrontab",
			} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/files/mycrontab").returns("abc123")
		@kuzushi.expects(:put_file).with("abc123", tmpfile = "/tmp/kuzushi/mycrontab")
		@kuzushi.expects(:shell).with("crontab -u root #{tmpfile}")
		should.not.raise { @kuzushi.start }
	end

	it "can handle a basic crontab with a specified source or a different user" do
		@kuzushi.stubs(:config).returns( {
			"crontab" => [ {
				"source" => "mycrontab",
				"user" => "bob",
			} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/files/mycrontab").returns("abc123")
		@kuzushi.expects(:put_file).with("abc123", tmpfile = "/tmp/kuzushi/mycrontab")
		@kuzushi.expects(:shell).with("crontab -u bob #{tmpfile}")
		should.not.raise { @kuzushi.start }
	end

	it "can handle a basic crontab with a specified source" do
		@kuzushi.stubs(:config).returns( {
			"crontab" => [ {
				"template" => "mycrontab.erb",
			} ] } )
		@kuzushi.expects(:http_get).with("#{@url}/templates/mycrontab.erb").returns("Hello <%= 'world' %>")
		@kuzushi.expects(:put_file).with("Hello world", tmpfile = "/tmp/kuzushi/mycrontab.erb")
		@kuzushi.expects(:shell).with("crontab -u root #{tmpfile}")
		should.not.raise { @kuzushi.start }
	end
end

