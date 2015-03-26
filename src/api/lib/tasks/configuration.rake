task :load_configuration_xml, [:file] => :environment do |t, args|
  args.with_defaults(:file => '/srv/obs/configuration.xml')
  puts "Reading file: #{args.file}"
  xml = Xmlhash.parse(File.read(args.file)) || {}
  attribs = {}

  # scheduler architecture list
  archs=nil
  if xml["schedulers"] and xml["schedulers"]["arch"].class == Array
    archs=Hash[xml["schedulers"]["arch"].map{|a| [a, 1]}]
  end
  if archs
    Architecture.all.each do |arch|
      if arch.available != (archs[arch.name] == 1)
        arch.available = (archs[arch.name] == 1)
        arch.save!
      end
    end
  end

  # standard values as defined in model
  ::Configuration::OPTIONS_YML.keys.each do |k|
    value = xml[k.to_s]
    if value and not value.blank?
      v = ::Configuration::map_value( k, value )
      ov = ::Configuration::map_value( k, ::Configuration::OPTIONS_YML[k] )
      if ov != v and not ov.blank?
        puts "The api has a different value for #{k.to_s} configured in options.yml file."
        next
      end
      attribs[k] = value
    end
  end

  @configuration = ::Configuration.first
  ret = @configuration.update_attributes(attribs)
  if ret
    puts "success"
    @configuration.save!
  else
    puts @configuration.errors
  end
end
