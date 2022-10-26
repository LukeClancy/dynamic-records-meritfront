require "dynamic-records-meritfront/version"
require 'hashid/rails'

module DynamicRecordsMeritfront
	extend ActiveSupport::Concern

	# the two aliases so I dont go insane
	module Hashid::Rails
		alias hid hashid
	end
	module Hashid::Rails::ClassMethods
		alias hfind find_by_hashid
	end

	included do
		# include hash id gem
		include Hashid::Rails
		#should work, probably able to override by redefining in ApplicationRecord class.
		#Note we defined here as it breaks early on as Rails.application returns nil
		PROJECT_NAME = Rails.application.class.to_s.split("::").first.to_s.downcase
		DYNAMIC_SQL_RAW = true
	end

	class MultiRowExpression
		#this class is meant to be used in congunction with headache_sql method
		#Could be used like so in headache_sql:
		
		#ApplicationRecord.headache_sql( "teeeest", %Q{
		#	INSERT INTO tests(id, username, is_awesome)
		#	VALUES :rows
		#	ON CONFLICT SET is_awesome = true
		#}, rows: [[1, luke, true], [2, josh, false]])
	
		#which would output this sql
	
		#	INSERT INTO tests(id, username, is_awesome)
		#	VALUES ($0,$1,$2),($3,$4,$5)
		#	ON CONFLICT SET is_awesome = true
	
		attr_accessor :val
		def initialize(val)
			#assuming we are putting in an array of arrays.
			self.val = val
		end
		def for_query(x = 0, unique_value_hash:)
			#accepts x = current number of variables previously processed
			#returns ["sql string with $# location information", variables themselves in order, new x]
			db_val = val.map{|attribute_array| "(#{
				attribute_index = 0
				attribute_array.map{|attribute|
					prexist_num = unique_value_hash[attribute]
					if prexist_num
						attribute_array[attribute_index] = nil
						ret = "$#{prexist_num}"
					else
						unique_value_hash[attribute] = x
						ret = "$#{x}"
						x += 1
					end
					attribute_index += 1
					next ret
				}.join(",")
			})"}.join(",")
			return db_val, val.flatten.select{|a| not a.nil?}, x
		end
	end

	def questionable_attribute_set(atr, value)
		#this is needed on initalization of a new variable after the actual thing has been made already.

		#set a bunk type of the generic value type
		@attributes.instance_variable_get(:@types)[atr] = ActiveModel::Type::Value.new
		#Set it
		self[atr] = value
	end

	def inspect
		#basically the same as the upstream active record function (as of october 25 2022 on AR V7.0.4)
		#except that I changed self.class.attribute_names -> self.attribute_names to pick up our
		#dynamic insanity. Was this a good idea? Well I guess its better than not doing it
		inspection = if defined?(@attributes) && @attributes
			self.attribute_names.filter_map do |name|
			if _has_attribute?(name)
				"#{name}: #{attribute_for_inspect(name)}"
			end
			end.join(", ")
		else
			"not initialized"
		end

		"#<#{self.class} #{inspection}>"
	end

	def do_terrible_code_sins_to_dynamically_add_attributes_to_ar_models(atr, value)
		#set a bunk type of the generic value type
		self.attributes.instance_variable_get(:@types)[atr] = ActiveModel::Type::Value.new
		#Set it
		self[atr] = value
	end

	module ClassMethods

		def has_run_migration?(nm)
		#put in a string name of the class and it will say if it has allready run the migration.
		#good during enum migrations as the code to migrate wont run if enumerate is there 
		#as it is not yet enumerated (causing an error when it loads the class that will have the
		#enumeration in it). This can lead it to being impossible to commit clean code.
		#
		# example usage one: only create the record class if it currently exists in the database
			# if ApplicationRecord.has_run_migration?('UserImageRelationsTwo')
			# 	class UserImageRelation < ApplicationRecord
			# 		belongs_to :imageable, polymorphic: true
			# 		belongs_to :image
			# 	end
			# else
			# 	class UserImageRelation; end
			# end
		# example usage two: only load relation if it exists in the database
			# class UserImageRelation < ApplicationRecord
			#	if ApplicationRecord.has_run_migration?('UserImageRelationsTwo')
			#	 	belongs_to :imageable, polymorphic: true
			#	end
			# end
		#	
			#current version of migrations
			cv = ActiveRecord::Base.connection.migration_context.current_version
			
			#find the migration object for the name
			migration = ActiveRecord::Base.connection.migration_context.migrations.filter!{|a|
					a.name == nm
				}.first

			#if the migration object is nil, it has not yet been created
			if migration.nil?
				Rails.logger.info "No migration found for #{nm}. The migration has not yet been created, or is foreign to this database."
				return false
			end
	
			#get the version number for the migration name
			needed_version = migration.version
	
			#if current version is above or equal, the migration has allready been run
			migration_ran = (cv >= needed_version)
	
			if migration_ran
				Rails.logger.info "#{nm} migration was run on #{needed_version}. If old and all instances are migrated, consider removing code check."
			else
				Rails.logger.info "#{nm} migration has not run yet. This may lead to limited functionality"
			end
	
			return migration_ran
		end
		def list_associations
			#lists associations (see has_association? below)
			reflect_on_all_associations.map(&:name)
		end
		def has_association?(*args)
			#checks whether current class has needed association (for example, checks it has comments)
			#associations can be seen in has_many belongs_to and other similar methods

			#flattens so you can pass self.has_association?(:comments, :baseable_comments) aswell as
			#		self.has_association?([:comments, :baseable_comments]) without issue
			#		
			args = args.flatten.map { |a| a.to_sym }
			associations = list_associations
			(args.length == (associations & args).length)
		end		
		def blind_hgid(id, tag: nil, encode: true)
		# this method is to get an hgid for a class without actually calling it down from the database.
		# For example Notification.blind_hgid 1 will give gid://PROJECT_NAME/Notification/69DAB69 etc.
			if id.class == Integer and encode
				id = self.encode_id id
			end
			gid = "gid://#{PROJECT_NAME}/#{self.to_s}/#{id}"
			if !tag
				gid
			else
				"#{gid}@#{tag}"
			end
		end
		def string_as_selector(str, attribute: 'id')
			#this is needed to allow us to quey various strange characters in the id etc. (see hgids)
			#also useful for querying various attributes
			return "*[#{attribute}=\"#{str}\"]"
		end
		def locate_hgid(hgid_string, with_associations: nil, returns_nil: false)
			if hgid_string == nil or hgid_string.class != String
				if returns_nil
					return nil
				else
					raise StandardError.new("non-string class passed to ApplicationRecord#locate_hgid as the hgid_string variable")
				end
			end
			if hgid_string.include?('@')
				hgid_string = hgid_string.split('@')
				hgid_string.pop
				hgid_string = hgid_string.join('@') # incase the model was a tag that was tagged. (few months later: Wtf? Guess ill keep it)
			end
			#split the thing
			splitz = hgid_string.split('/')
			#get the class
			begin
				cls = splitz[-2].constantize
			rescue NameError, NoMethodError
				if returns_nil
					nil
				else
					raise StandardError.new 'Unusual or unavailable string or hgid'
				end
			end
			#get the hash
			hash = splitz[-1]
			# if self == ApplicationRecord (for instance), then check that cls is a subclass
			# if self is not ApplicationRecord, then check cls == this objects class
			# if with_associations defined, make sure that the class has the associations given (see has_association above)
			if ((self.abstract_class? and cls < self) or ( (not self.abstract_class?) and cls == self )) and
				( with_associations == nil or cls.has_association?(with_associations) )
				#if all is as expected, return the object with its id.
				if block_given?
					yield(hash)
				else
					cls.hfind(hash)
				end
			elsif returns_nil
				#allows us to handle issues with input
				nil
			else
				#stops execution as default
				raise StandardError.new 'Not the expected class, or a subclass of ApplicationRecord if called on that.'
			end
		end
		def get_hgid_tag(hgid_string)
			if hgid_string.include?('@')
				return hgid_string.split('@')[-1]
			else
				return nil
			end
		end

		#thank god for some stack overflow people are pretty awesome https://stackoverflow.com/questions/64894375/executing-a-raw-sql-query-in-rails-with-an-array-parameter-against-postgresql
		#BigIntArray = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveModel::Type::BigInteger.new).freeze
		#IntegerArray = ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(ActiveModel::Type::Integer.new).freeze

		#https://api.rubyonrails.org/files/activemodel/lib/active_model/type_rb.html
		# active_model/type/helpers
		# active_model/type/value
		# active_model/type/big_integer
		# active_model/type/binary
		# active_model/type/boolean
		# active_model/type/date
		# active_model/type/date_time
		# active_model/type/decimal
		# active_model/type/float
		# active_model/type/immutable_string
		# active_model/type/integer
		# active_model/type/string
		# active_model/type/time
		# active_model

		DB_TYPE_MAPS = {
			String => ActiveModel::Type::String,
			Symbol => ActiveModel::Type::String,
			Integer => ActiveModel::Type::BigInteger,
			BigDecimal => ActiveRecord::Type::Decimal,
			TrueClass => ActiveModel::Type::Boolean,
			FalseClass => ActiveModel::Type::Boolean,
			Date => ActiveModel::Type::Date,
			DateTime => ActiveModel::Type::DateTime,
			Time => ActiveModel::Type::Time,
			Float => ActiveModel::Type::Float,
			Array =>  Proc.new{ |first_el_class| ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(DB_TYPE_MAPS[first_el_class].new) }
		}

		def convert_to_query_attribute(name, v)
			#yes its dumb I know dont look at me look at rails
	
			# https://stackoverflow.com/questions/40407700/rails-exec-query-bindings-ignored
			# binds = [ ActiveRecord::Relation::QueryAttribute.new(
			# 	"id", 6, ActiveRecord::Type::Integer.new
			# )]
			# ApplicationRecord.connection.exec_query(
			# 	'SELECT * FROM users WHERE id = $1', 'sql', binds
			# )
	
			return v if v.kind_of? ActiveRecord::Relation::QueryAttribute	#so users can have fine-grained control if they are trying to do something
				#that we didn't handle properly.
	
			type = DB_TYPE_MAPS[v.class]
			if type.nil?
				raise StandardError.new("#{v}'s class #{v.class} unsupported type right now for ApplicationRecord#headache_sql")
			elsif type.class == Proc
				a = v[0]
				# if a.nil?
				# 	a = Integer
				# elsif a.class == Array
				a = a.nil? ? Integer : a.class
				type = type.call(a)
			else
				type = type.new
			end
			
			ActiveRecord::Relation::QueryAttribute.new( name, v, type )
		end
		#allows us to preload on a list and not a active record relation. So basically from the output of headache_sql
		def dynamic_preload(records, associations)
			ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
		end

		alias headache_preload dynamic_preload
		
		def dynamic_sql(name, sql, opts = { }) #see below for opts
			# - instantiate_class - returns User, Post, etc objects instead of straight sql output.
			#		I prefer doing the alterantive
			#			User.headache_class(...)
			#		which is also supported
			# - prepare sets whether the db will preprocess the strategy for lookup (defaults true) (I dont think turning this off works...)
			# - name_modifiers allows one to change the preprocess associated name, useful in cases of dynamic sql.
			# - multi_query allows more than one query (you can seperate an insert and an update with ';' I dont know how else to say it.)
			#		this disables other options (except name_modifiers). Not sure how it effects prepared statements. Its a fairly useless
			#		command as you can do multiple queries anyway with 'WITH' statements and also gain the other options.
			# - async does what it says but I haven't used it yet so. Probabably doesn't work
			# - raw switches between using a Hash or a ActiveRecord::Response object when used on a abstract class

			#
			# Any other option is assumed to be a sql argument (see other examples in code base)

			#grab options from the opts hash
			instantiate_class = opts.delete(:instantiate_class)
			name_modifiers = opts.delete(:name_modifiers)
			raw = opts.delete(:raw)
			raw = DYNAMIC_SQL_RAW if raw.nil?
			name_modifiers ||= []
			prepare = opts.delete(:prepare) != false
			multi_query = opts.delete(:multi_query) == true
			async = opts.delete(:async) == true
			params = opts

			#unique value hash cuts down on the number of repeated arguments like in an update or insert statement
			#by checking if there is an equal existing argument and then using that argument number instead.
			#If this functionality is used at a lower level we should probably remove this.
			unique_value_hash = {}

			#allows dynamic sql prepared statements.
			for mod in name_modifiers
				name << "_#{mod.to_s}" unless mod.nil?
			end

			unless multi_query
				#https://stackoverflow.com/questions/49947990/can-i-execute-a-raw-sql-query-leverage-prepared-statements-and-not-use-activer/67442353#67442353
				#change the keys to $1, $2 etc. this step is needed for ex. {id: 1, id_user: 2}.
				#doing the longer ones first prevents id replacing :id_user -> 1_user
				keys = params.keys.sort{|a,b| b.to_s.length <=> a.to_s.length}
				sql_vals = []
				x = 1
				for key in keys
					#replace the key with $1, $2 etc
					v = params[key]

					#this is where we guess what it is
					looks_like_multi_attribute_array = ((v.class == Array) and (not v.first.nil?) and (v.first.class == Array))

					if v.class == MultiRowExpression or looks_like_multi_attribute_array
					#it looks like or is a multi-row expression (like those in an insert statement)
						v = MultiRowExpression.new(v) if looks_like_multi_attribute_array
						#process into usable information
						sql_for_replace, mat_vars, new_x = v.for_query(x, unique_value_hash: unique_value_hash)
						#replace the key with the sql
						if sql.gsub!(":#{key}", sql_for_replace) != nil
						#if successful set the new x number and append variables to our sql variables
							x = new_x
							name_num = 0
							mat_vars.each{|mat_var|
								name_num += 1
								sql_vals << convert_to_query_attribute("#{key}_#{name_num}", mat_var)
							}
						end
					else
						prexist_arg_num = unique_value_hash[v]
						if prexist_arg_num
							sql.gsub!(":#{key}", "$#{prexist_arg_num}")
						else
							if sql.gsub!(":#{key}", "$#{x}") == nil
								#nothing changed, param not used, delete it
								params.delete key
							else
								unique_value_hash[v] = x
								sql_vals << convert_to_query_attribute(key, v)
								x += 1
							end
						end
					end
				end
				ret = ActiveRecord::Base.connection.exec_query sql, name, sql_vals, prepare: prepare, async: async
			else
				ret = ActiveRecord::Base.connection.execute sql, name
			end

			#this returns a PG::Result object, which is pretty basic. To make this into User/Post/etc objects we do
					#the following
			if instantiate_class or not self.abstract_class
				instantiate_class = self if not instantiate_class
				#no I am not actually this cool see https://stackoverflow.com/questions/30826015/convert-pgresult-to-an-active-record-model
				ret = zip_ar_result(ret)
				return ret.map{|r| dynamic_init(instantiate_class, r)}
				# fields = ret.columns
				# vals = ret.rows
				# ret = vals.map { |v|
				# 	dynamic_init()
				# 	instantiate_class.instantiate(Hash[fields.zip(v)])
				# }
			else
				if raw
					return ret
				else
					return zip_ar_result(ret)
				end
			end
		end
		alias headache_sql dynamic_sql
		
		def instaload(sql, table_name: nil, relied_on: false)
			table_name ||= "_" + self.to_s.underscore.downcase.pluralize
			klass = self.to_s
			sql = "\t" + sql.strip
			return {table_name: table_name, klass: klass, sql: sql, relied_on: relied_on}
		end

		def _dynamic_instaload_handle_with_statements(with_statements)
			%Q{WITH #{
	with_statements.map{|ws|
		"#{ws[:table_name]} AS (\n#{ws[:sql]}\n)"
	}.join(", \n")
}}
		end

		def _dynamic_instaload_union(insta_array)
			insta_array.map{|insta|
				start = "SELECT row_to_json(#{insta[:table_name]}.*) AS row, '#{insta[:klass]}' AS _klass, '#{insta[:table_name]}' AS _table_name FROM "
				if insta[:relied_on]
					ending = "#{insta[:table_name]}\n"
				else
					ending = "(\n#{insta[:sql]}\n) AS #{insta[:table_name]}\n"
				end
				next start + ending
			}.join(" UNION ALL \n")
			#{ other_statements.map{|os| "SELECT row_to_json(#{os[:table_name]}.*) AS row, '#{os[:klass]}' AS _klass FROM (\n#{os[:sql]}\n)) AS #{os[:table_name]}\n" }.join(' UNION ALL ')}
		end

		def dynamic_instaload_sql(name, insta_array, opts = { })
			with_statements = insta_array.select{|a| a[:relied_on]}
			sql = %Q{
#{ _dynamic_instaload_handle_with_statements(with_statements) if with_statements.any? }
#{ _dynamic_instaload_union(insta_array)}
}
			ret_hash = insta_array.map{|ar| [ar[:table_name].to_s, []]}.to_h
			opts[:raw] = true
			ApplicationRecord.headache_sql(name, sql, opts).rows.each{|row|
				#need to pre-parsed as it has a non-normal output.
				table_name = row[2]
				klass = row[1].constantize
				json = row[0]
				parsed = JSON.parse(json)

				ret_hash[table_name ].push dynamic_init(klass, parsed)
			}
			return ret_hash
		end
		alias swiss_instaload_sql dynamic_instaload_sql

		

		def dynamic_attach(instaload_sql_output, base_name, attach_name, base_on: nil, attach_on: nil, one_to_one: false)
			base_arr = instaload_sql_output[base_name]
			
			#return if there is nothing for us to attach to.
			return unless base_arr.any?

			#set variables for neatness and so we dont compute each time
			#	base class information
			base_class = base_arr.first.class
			base_class_is_hash = base_class <= Hash
			
			
			#variable accessors and defaults.
			base_arr.each{ |o|
				#
				#   there is no way to set an attribute after instantiation I tried I looked
				#   I dealt with silent breaks on symbol keys, I have wasted time, its fine.
				
				if not base_class_is_hash
					if one_to_one
						#attach name must be a string
						o.questionable_attribute_set(attach_name, nil)
					else
						o.questionable_attribute_set(attach_name, [])
					end
				end
				# o.dynamic o.singleton_class.public_send(:attr_accessor, attach_name_sym) unless base_class_is_hash
				# o.instance_variable_set(attach_name_with_at, []) unless one_to_one
			}

			#make sure the attach class has something going on
			attach_arr = instaload_sql_output[attach_name]
			return unless attach_arr.any?
			
			#	attach class information
			attach_class = attach_arr.first.class
			attach_class_is_hash = attach_class <= Hash

			#	default attach column info
			default_attach_col = (base_class.to_s.downcase + "_id")

			#decide on the method of getting the matching id for the base table
			unless base_on
				if base_class_is_hash
					base_on = Proc.new{|x| x['id']}
				else
					base_on = Proc.new{|x| x.id}
				end
			end

			#return an id->object hash for the base table for better access
			h = base_arr.map{|o| 
				[base_on.call(o), o]
			}.to_h
			
			#decide on the method of getting the matching id for the attach table
			unless attach_on
				if attach_class_is_hash
					attach_on = Proc.new{|x| x[default_attach_col]}
				else
					attach_on = Proc.new{|x| 
						x.attributes[default_attach_col]
					}
				end
			end

			# if debug
			# 	Rails.logger.info(base_arr.map{|b|
			# 		base_on.call(b)
			# 	})
			# 	Rails.logger.info(attach_arr.map{|a|
			# 		attach_on.call(a)
			# 	})
			# end

			#method of adding the object to the base
			#(b=base, a=attach)
			add_to_base = Proc.new{|b, a|
				if one_to_one
					b[attach_name] = a
				else
					b[attach_name].push a
				end
			}

			#for every attachable
			#	1. match base id to the attach id (both configurable)
			#	2. cancel out if there is no match
			#	3. otherwise add to the base object.
			attach_arr.each{|attach|
				if out = attach_on.call(attach) #you can use null to escape the vals
					if base = h[out] #it is also escaped if no base element is found
						add_to_base.call(base, attach)
					end
				end
			}
			return attach_arr
		end
		alias swiss_attach dynamic_attach

		def zip_ar_result(x)
			fields = x.columns
			vals = x.rows
			vals.map { |v|
				Hash[fields.zip(v)]
			}
		end

		def dynamic_init(klass, input)
			if klass.abstract_class
				return input
			else
				record = klass.instantiate(input.stringify_keys ) #trust me they need to be stringified
				# #handle attributes through ar if allowed. Throws an error on unkown variables, except apparently for devise classes? 😡
				# active_record_handled = input.slice(*(klass.attribute_names & input.keys))
				# record = klass.instantiate(active_record_handled)
				# #set those that were not necessarily expected
				# not_expected = input.slice(*(input.keys - klass.attribute_names))
				# record.dynamic = OpenStruct.new(not_expected.transform_keys{|k|k.to_sym}) if not_expected.keys.any?
				return record
			end
		end

		def quick_safe_increment(id, col, val)
			where(id: id).update_all("#{col} = #{col} + #{val}")
		end

		
	end

	def list_associations
		#lists associations (see class method above)
		self.class.list_associations
	end

	def has_association?(*args)
		#just redirects to the class method for ease of use (see class method above)
		self.class.has_association?(*args)
	end

	# custom hash GlobalID
	def hgid(tag: nil)
		gid = "gid://#{PROJECT_NAME}/#{self.class.to_s}/#{self.hid}"
		if !tag
			gid
		else
			"#{gid}@#{tag}"
		end
	end
	alias ghid hgid #its worth it trust me the amount of times i go 'is it hash global id or global hashid?'

	def hgid_as_selector(tag: nil, attribute: 'id')
		#https://www.javascripttutorial.net/javascript-dom/javascript-queryselector/
		gidstr = hgid(tag: tag).to_s
		return self.class.string_as_selector(gidstr, attribute: attribute)
	end

	#just for ease of use
	def headache_preload(records, associations)
			self.class.headache_preload(records, associations)
	end
	def safe_increment(col, val) #also used in follow, also used in comment#kill
		self.class.where(id: self.id).update_all("#{col} = #{col} + #{val}")
	end

end
