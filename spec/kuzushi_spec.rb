require File.dirname(__FILE__) + '/base'

describe Kuzushi do
	before do
		# hello 
	end
	
	it "is a class" do
		Kuzushi.class.should == Class
	end
end
