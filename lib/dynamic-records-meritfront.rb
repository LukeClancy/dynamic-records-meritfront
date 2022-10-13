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
		
		def blind_hgid(id, tag: nil)
		# this method is to get an hgid for a class without actually calling it down from the database.
		# For example Notification.blind_hgid 1 will give gid://PROJECT_NAME/Notification/69DAB69 etc.
			unless id.class == String
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
		def headache_preload(records, associations)
			ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
		end

		def headache_sql(name, sql, opts = { }) #see below for opts
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
            #
            # Any other option is assumed to be a sql argument (see other examples in code base)
    
            #grab options from the opts hash
            instantiate_class = opts.delete(:instantiate_class)
            name_modifiers = opts.delete(:name_modifiers)
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
            if instantiate_class or self != ApplicationRecord
                instantiate_class = self if not instantiate_class
                #no I am not actually this cool see https://stackoverflow.com/questions/30826015/convert-pgresult-to-an-active-record-model
                fields = ret.columns
                vals = ret.rows
                ret = vals.map { |v|
                    instantiate_class.instantiate(Hash[fields.zip(v)])
                }
            end
            ret
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
