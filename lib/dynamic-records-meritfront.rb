require "dynamic-records-meritfront/version"
require 'hashid/rails'

#this file contains multiple classes which should honestly be split up.

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
        attr_accessor :dynamic_reflections
    end

    class DynamicSqlVariables
        attr_accessor :sql_hash
        attr_accessor :params
        def initialize(params)
            @sql_hash = {}
            self.params = params
        end

        def key_index(key)
            k = sql_hash.keys.index(key)
            k += 1 unless k.nil?
            k
        end

        def add_key_value(key, value = nil)
            value = params[key] if value.nil?
            #tracks the variable and returns the keys sql variable number
            sql_hash[key] ||= convert_to_query_attribute(key, value)
            return key_index(key)
        end

        def next_sql_num
            #gets the next sql variable number
            sql_hash.keys.length + 1
        end

        def get_array_for_exec_query
            sql_hash.values
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
            ActiveSupport::SafeBuffer => ActiveModel::Type::String,
            Integer => ActiveModel::Type::BigInteger,
            BigDecimal => ActiveRecord::Type::Decimal,
            TrueClass => ActiveModel::Type::Boolean,
            FalseClass => ActiveModel::Type::Boolean,
            Date => ActiveModel::Type::Date,
            DateTime => ActiveModel::Type::DateTime,
            Time => ActiveModel::Type::Time,
            Float => ActiveModel::Type::Float,
		NilClass => ActiveModel::Type::Boolean,
            Array =>  Proc.new{ |first_el_class| ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(DB_TYPE_MAPS[first_el_class].new) } #this one was a mistake
        }

        def convert_to_query_attribute(name, v)
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
                raise StandardError.new("#{name} (of value: #{v}, class: #{v.class}) unsupported class for DynamicRecordsMeritfront#headache_sql")
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
        def for_query(key, var_track)
            #accepts x = current number of variables previously processed
            #returns ["sql string with $# location information", variables themselves in order, new x]
            x = -1
            db_val = val.map{|attribute_array| "(#{
                attribute_array.map{|attribute|
                    if attribute.kind_of? Symbol
                        #allow pointers to other more explicit variables through symbols
                        x = var_track.add_key_value(attribute, nil)
                    else
                        k = "#{key}_#{var_track.next_sql_num.to_s}"
                        x = var_track.add_key_value(k, attribute)
                    end
                    next "$" + x.to_s
                }.join(",")
            })"}.join(",")
            return db_val
        end
    end

    def questionable_attribute_set(atr, value, as_default: false, push: false)
        #this is needed on initalization of a new variable after the actual thing has been made already.
        #this is used for attaching records to other records in one-to-one or one-to-many

        #basically the way this works is by using singletons to paper over the fact that normal reflections
        #even exist. We dont integrate at all with their patterns as they use some crazy delegation stuff
        #that messes just about everything up.

        #man i thought i was meta coding, these association people just want to see the world burn.

        #keeping the old code commented for a while because this area keeps breaking and i want a log of what i have tried.

        self.dynamic_reflections ||= []

        unless dynamic_reflections.include?(atr.to_s)
            self.dynamic_reflections << atr.to_s
            singleton_class.instance_eval do 
                attr_accessor atr.to_sym
            end
        end
    #    # if _reflections.keys.include? atr.to_s
    #     has_method = methods.include?(atr.to_sym)
    #     
    #     DevScript.ping(has_method)
    #     override = (not(has_method) or (
    #         _reflections.keys.include? atr.to_s
    #         and not
            
    #     )
    #     DevScript.ping(override)

    #     if override
            
            
    #     end
        #elsif
                
        #end

        # pi = atr.to_sym == :current_user_follow
        #DevScript.ping(self.inspect) if pi
        if as_default
            if self.method(atr.to_sym).call().nil?
                self.method("#{atr}=".to_sym).call(value)
                # Rails.logger.info "Y #{value.followable_type if value.respond_to? :followable_type}" if pi
            end
            # Rails.logger.info "#{atr} ||= #{value}" if pi
        elsif push
            self.method(atr.to_sym).call().push value
         #   Rails.logger.info #{atr} << #{value}" if pi
            # DevScript.ping("atr #{atr} push #{value}")
        else
            #out =
            self.method("#{atr}=".to_sym).call(value)
            # Rails.logger.info "[#{self.class.to_s} #{self.id}].#{atr} -> #{out.inspect}" if pi
            # DevScript.ping("atr #{atr} set #{value}")
        end
        #Rails.logger.info self.inspect if pi

#        raise StandardError.new('bad options') if as_default and push
#        if as_default
#            unless self.respond_to? atr
#                #make sure its accesible in some way
#                values = @attributes.instance_variable_get(:@values)
#                if not values.keys.include?(atr)
#                    values[atr] = value
#                end
#            end
#        else
#            if self.reflections.keys.include? atr.to_s
#		
#            else
#                values ||= @attributes.instance_variable_get(:@values)
#                values[atr] << value
#                
#            
#            end
#            #no getter/setter methodsout, probably catches missing methods and then redirects to attributes. Lots of magic.
#            #   After multiple attempts, I gave up, so now we use eval. I guess I cant be too mad about magic as
#            #   that seems to be my bread and butter. Hope eval doesnt make it go too slow. Guess everything is evaled
#            #   on some level though?
#            s = self    #afraid self will be a diffrent self in eval. Possibly depending on parser. IDK. Just seemed risky.
#            if push
#                eval "s.#{atr} << value"
#            else
#                eval "s.#{atr} = value"
#            end
#        end

        # atr = atr.to_s
        # setter = "#{atr}="
        # if respond_to?(setter)
        #     #this allows us to attach to ActiveRecord relations and standard columns as we expect.
        #     #accessors etc will be triggered as expected.
        #     if push
        #         method(atr).call().push(value)
        #     else
        #         method(setter).call(value)
        #     end
        # else
        #     #for non-standard columns (one that is not expected by the record),
        #     #this allows us to attach to the record, and access the value as we are acustomed to.
        #     #when you 'save!' it interestingly seems to know thats not a normal column expected by
        #     #the model, and will ignore it.

        #     values = @attributes.instance_variable_get(:@values)
        #     else
        #         if as_default
        #             self[atr] = value if self[atr].nil?
        #         else
        #             if push
        #                 self[atr] << value
        #             else
        #                 self[atr] = value
        #             end
        #         end 
        #     end
        # end
    end

    def inspect
        #basically the same as the upstream active record function (as of october 25 2022 on AR V7.0.4)
        #except that I changed self.class.attribute_names -> self.attribute_names to pick up our
        #dynamic insanity. Was this a good idea? Well I guess its better than not doing it

        #I also added dynamic_reflections

        inspection = if defined?(@attributes) && @attributes
            self.attribute_names.filter_map do |name|
            if _has_attribute?(name)
                "#{name}: #{attribute_for_inspect(name)}"
            end
            end.join(", ")
        else
            "not initialized"
        end

        self.dynamic_reflections ||= []
        dyna = self.dynamic_reflections.map{|dr|
            [dr, self.method(dr.to_sym).call()]
        }.to_h

        if dyna.keys.any?
            "#<#{self.class} #{inspection} | #{dyna.to_s}>"
        else
            "#<#{self.class} #{inspection}>"
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
                    raise StandardError.new("non-string class passed to DynamicRecordsMeritfront#locate_hgid as the hgid_string variable")
                end
            end
            if PROJECT_NAME == 'midflip'
                #should be fine to take out in a month or so, just got lazy and pretty sure I am the only one using this gem.
                #dont want to kill me jobs.
                hgid_string = hgid_string.gsub('ApplicationRecord', 'Record')
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
                raise StandardError.new 'Not the expected class or subclass.'
            end
        end
        def get_hgid_tag(hgid_string)
            if hgid_string.include?('@')
                return hgid_string.split('@')[-1]
            else
                return nil
            end
        end

        #allows us to preload on a list and not a active record relation. So basically from the output of headache_sql
        def dynamic_preload(records, associations)
            ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
        end

        alias headache_preload dynamic_preload
        
        def dynamic_sql(*args) #see below for opts
        # call like: dynamic_sql(name, sql, option_1: 1, option_2: 2)
        #   or like: dynamic_sql(sql, {option: 1, option_2: 2})
        #   or like: dynamic_sql(sql, option: 1, option_2: 2)
        #	or just: dynamic_sql(sql)
        #
        # Options: (options not listed will be sql arguments)
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
            args << {} unless args[-1].kind_of? Hash
            if args.length == 3
                name, sql, opts = args
            elsif args.length == 2
                sql, opts = args
                #give default name functionality as a pointer to source code location
                #of the method that called this. Love ruby. Meta up the a$$
                first_app_stack_trace = caller[0...3].select{|str| not str.include?('dynamic_records_meritfront.rb')}.first
                shorter_source_loc = first_app_stack_trace.split('/')[-1]
                name = shorter_source_loc
            else
                raise StandardError.new("bad input to DynamicRecordsMeritfront#dynamic_sql method.")
            end

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
                #________________________________
                #got this error: ActiveRecord::StatementInvalid (PG::ProtocolViolation: ERROR:  bind message supplies 3 parameters, but prepared statement "a27" requires 4)
                #this error tells me two things
                #   1. the name of a sql statement actually has no effect on prepared statements (whoops).
                #       This means we should accept queries with no name.
                #   2. Need to get rid of the unique variable name functionality which uniques all the variables
                #       to decrease the amount sent to database

            #name_modifiers are super unnecessary now I realize the given name is not actually related
            #to prepped statements. But will keep it as it is backwards compatitable and sorta useful maybe.
            for mod in name_modifiers
                name << "_#{mod.to_s}" unless mod.nil?
            end
            begin
                var_track = DynamicSqlVariables.new(params)
                unless multi_query
                    #https://stackoverflow.com/questions/49947990/can-i-execute-a-raw-sql-query-leverage-prepared-statements-and-not-use-activer/67442353#67442353
                    #change the keys to $1, $2 etc. this step is needed for ex. {id: 1, id_user: 2}.
                    #doing the longer ones first prevents id replacing :id_user -> $1_user
                    keys = params.keys.sort{|a,b| b.to_s.length <=> a.to_s.length}

                    for key in keys
                        #replace MultiRowExpressions
                        v = params[key]
                        #check if it looks like one
                        looks_like_multi_row_expression = ((v.class == Array) and (not v.first.nil?) and (v.first.class == Array))
                        if v.class == MultiRowExpression or looks_like_multi_row_expression
                        #we need to substitute with the correct sql now.
                            v = MultiRowExpression.new(v) if looks_like_multi_row_expression #standardize
                            #process into appropriate sql while keeping track of variables
                            sql_for_replace = v.for_query(key, var_track)
                            #replace the key with the sql
                            sql.gsub!(":#{key}", sql_for_replace)
                        else
                            #check if its currently in the sql argument list
                            x = var_track.key_index(key)
                            if x.nil?
                                #if not, get the next number that it will be assigned and replace the key w/ that number.
                                x = var_track.next_sql_num
                                if sql.gsub!(":#{key}", "$#{x}")
                                    #only actually add to sql arguments when we know the attribute was used.
                                    var_track.add_key_value(key, v)
                                end
                            else
                                #its already in use as a sql argument and has a number, use that number.
                                sql.gsub!(":#{key}", "$#{x}")
                            end
                        end
                    end
                    sql_vals = var_track.get_array_for_exec_query
                    ret = ActiveRecord::Base.connection.exec_query sql, name, sql_vals, prepare: prepare, async: async
                else
                    ret = ActiveRecord::Base.connection.execute sql, name
                end
            rescue Exception => e
                #its ok if some of these are empty, just dont want the error
                name ||= ''
                sql ||= ''
                sql_vals ||= ''
                prepare ||= ''
                async ||= ''
                Rails.logger.error(%Q{
    DynamicRecords#dynamic_sql debug info.
    name: #{name.to_s}
    sql: #{sql.to_s}
    sql_vals: #{sql_vals.to_s}
    prepare: #{prepare.to_s}
    async: #{async.to_s}
    })
                raise e
            end

            #this returns a PG::Result object, which is pretty basic. To make this into User/Post/etc objects we do
                    #the following
            if instantiate_class or not self.abstract_class
                instantiate_class = self if not instantiate_class
                #no I am not actually this cool see https://stackoverflow.com/questions/30826015/convert-pgresult-to-an-active-record-model
                ret = ret.to_a
                return ret.map{|r| dynamic_init(instantiate_class, r)}
            else
                if raw
                    return ret
                else
                    return ret.to_a
                end
            end
        end
        alias headache_sql dynamic_sql

        def _dynamic_instaload_handle_with_statements(with_statements)
            %Q{WITH #{
    with_statements.map{|ws|
        "#{ws[:table_name]} AS (\n#{ws[:sql]}\n)"
    }.join(", \n")
}}
        end

        def _dynamic_instaload_union(insta_array)
            insta_array.select{|insta|
                not insta[:dont_return]
            }.map{|insta|
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

        def instaload(sql, table_name: nil, relied_on: false, dont_return: false, base_name: nil, base_on: nil, attach_on: nil, one_to_one: false, as: nil)
            #this function just makes everything a little easier to deal with by providing defaults, making it nicer to call, and converting potential symbols to strings.
            #At the end of the day it just returns a hash with the settings in it though. So dont overthink it too much.

            as = as.to_s if as
            base_name = base_name.to_s if base_name
            
            if table_name
                table_name = table_name.to_s
            else
                table_name = "_" + self.to_s.underscore.downcase.pluralize
            end

            klass = self.to_s

            sql = "\t" + sql.strip
            raise StandardError.new("base_on needs to be nil or a Proc") unless base_on.nil? or base_on.kind_of? Proc
            raise StandardError.new("attach_on needs to be nil or a Proc") unless attach_on.nil? or attach_on.kind_of? Proc
            return {table_name: table_name, klass: klass, sql: sql, relied_on: relied_on, dont_return: dont_return, base_name: base_name, base_on: base_on, attach_on: attach_on, one_to_one: one_to_one, as: as}
        end

        def instaload_sql(*args) #name, insta_array, opts = { })
            args << {} unless args[-1].kind_of? Hash
            if args.length == 3
                name, insta_array, opts = args
            elsif args.length == 2
                insta_array, opts = args
                name = nil
            else
                raise StandardError.new("bad input to DynamicRecordsMeritfront#instaload_sql method.")
            end

            with_statements = insta_array.select{|a| a[:relied_on]}
            sql = %Q{
#{ _dynamic_instaload_handle_with_statements(with_statements) if with_statements.any? }
#{ _dynamic_instaload_union(insta_array)}
}
            insta_array = insta_array.select{|ar| not ar[:dont_return]}
            ret_hash = insta_array.map{|ar| [ar[:table_name].to_s, []]}.to_h
            opts[:raw] = true

            #annoying bug
            s = self
            unless s.abstract_class?
                s = s.superclass
            end
            
            s.dynamic_sql(name, sql, opts).rows.each{|row|
                #need to pre-parsed as it has a non-normal output.
                table_name = row[2]
                klass = row[1].constantize
                json = row[0]
                parsed = JSON.parse(json)
                ret_hash[table_name].push dynamic_init(klass, parsed)
            }

            insta_array.each{|a| a.delete(:sql)}
            
            #formatting options
            for insta in insta_array
                if insta[:base_name]
                    #in this case, 'as' is meant as to what pseudonym to dynamicly attach it as
                    #we are attaching to the base table. Variable could of been less confusing. My bad.
                    dynamic_attach(ret_hash, insta[:base_name], insta[:table_name], base_on: insta[:base_on], attach_on: insta[:attach_on],
                        one_to_one: insta[:one_to_one], as: insta[:as])
                elsif insta[:as]
                    Rails.logger.debug "#{insta[:table_name]} as #{insta[:as]}"
                    #in this case, the idea is more polymorphic in nature. unless they are confused and just want to rename the table (this can be done with
                    #      table_name)
                    if ret_hash[insta[:as]]
                        ret_hash[insta[:as]] += ret_hash[insta[:table_name]]
                    else
                        ret_hash[insta[:as]] = ret_hash[insta[:table_name]].dup #only top level dup
                    end
                else
                    Rails.logger.debug "#{insta[:table_name]}"
                end
            end

            return ret_hash
        end
        alias swiss_instaload_sql instaload_sql
        alias dynamic_instaload_sql instaload_sql

        def test_drmf(model_with_an_id_column_and_timestamps)
            m = model_with_an_id_column_and_timestamps
            ar = m.superclass
            mtname = m.table_name
            transaction do
                puts 'test recieving columns not normally in the record.'
                rec = m.dynamic_sql(%Q{
                    SELECT id, 5 AS random_column from #{mtname} LIMIT 10
                }).first
                raise StandardError.new('no id') unless rec.id
                raise StandardError.new('no dynamic column') unless rec.random_column
                puts 'pass 1'
                
                puts 'test raw off with a custom name'
                recs = ar.dynamic_sql('test_2', %Q{
                    SELECT id, 5 AS random_column from #{mtname} LIMIT 10
                }, raw: false)
                raise StandardError.new('not array of hashes') unless recs.first.class == Hash and recs.class == Array
                rec = recs.first
                raise StandardError.new('no id [raw off]') unless rec['id']
                raise StandardError.new('no dynamic column [raw off]') unless rec['random_column']
                puts 'pass 2'

                puts 'test raw on'
                recs = ar.dynamic_sql('test_3', %Q{
                    SELECT id, 5 AS random_column from #{mtname} LIMIT 10
                }, raw: true)
                raise StandardError.new('not raw') unless recs.class == ActiveRecord::Result
                rec = recs.first
                raise StandardError.new('no id [raw]') unless rec['id']
                raise StandardError.new('no dynamic column [raw]') unless rec['random_column']
                puts 'pass 3'

                puts 'test when some of the variables are diffrent then the same (#see version 3.0.1 notes)'
                x = Proc.new { |a, b|
                    recs = ar.dynamic_sql('test_4', %Q{
                        SELECT id, 5 AS random_column from #{mtname} WHERE id > :a LIMIT :b
                    }, a: a, b: b)
                }
                x.call(1, 2)
                x.call(1, 1)
                puts 'pass 4'

                puts 'test MultiAttributeArrays, including symbols and duplicate values.'
                time = DateTime.now
                ids = m.limit(5).pluck(:id)
                values = ids.map{|id|
                    [id, :time, time]
                }
                ar.dynamic_sql(%Q{
                    INSERT INTO #{mtname} (id, created_at, updated_at)
                    VALUES :values
                    ON CONFLICT (id) DO NOTHING
                }, values: values, time: time)
                puts 'pass 5'
                
                puts 'test arrays'
                recs = ar.dynamic_sql(%Q{
                    SELECT id from #{mtname} where id = ANY(:idz)
                }, idz: ids, raw: false)
                puts recs
                raise StandardError.new('wrong length') if recs.length != 5
                puts 'pass 6'

                
                puts 'test instaload_sql'
                out = ar.instaload_sql([
                    ar.instaload("SELECT id FROM users", relied_on: true, dont_return: true, table_name: "users_2"),
                    ar.instaload("SELECT id FROM users_2 WHERE id % 2 != 0 LIMIT :limit", table_name: 'a'),
                    m.instaload("SELECT id FROM users_2 WHERE id % 2 != 1 LIMIT :limit", table_name: 'b')
                ], limit: 2)
                puts out
                raise StandardError.new('Bad return') if out["users_2"]
                raise StandardError.new('Bad return') unless out["a"]
                raise StandardError.new('Bad return') unless out["b"]
                puts 'pass 7'

                puts "test dynamic_sql V3.0.6 error to do with multi_attribute_arrays which is hard to describe"
                time = DateTime.now
                values = [[1, :time, :time], [2, :time, :time]]
                out = ar.dynamic_sql(%Q{
                    insert into #{mtname} (id, created_at, updated_at)
                    values :values
                    on conflict (id)
                    do update set updated_at = :time
                }, time: time, values: values)
                puts 'pass 8'

                raise ActiveRecord::Rollback
                #ApplicationRecord.dynamic_sql("SELECT * FROM")
            end
        end

        def dynamic_attach(instaload_sql_output, base_name, attach_name, base_on: nil, attach_on: nil, one_to_one: false, as: nil)
            #as just lets it attach us anywhere on the base class, and not just as the attach_name.
            #Can be useful in polymorphic situations, otherwise may lead to confusion.
            
            #oh the errors
            base_name = base_name.to_s
            attach_name = attach_name.to_s

            as ||= attach_name

            base_arr = instaload_sql_output[base_name]
            
            #return if there is nothing for us to attach to.
            if base_arr.nil? or not base_arr.any?
                Rails.logger.warn("unable to find base attach table " + base_name)
                return 0
            end

            #set variables for neatness and so we dont compute each time
            #	base class information
            base_class = base_arr.first.class
            base_class_is_hash = base_class <= Hash
            
            #variable accessors and defaults. Make sure it only sets if not defined already as
            #the 'as' option allows us to override to what value it actually gets set in the end, 
            #and in polymorphic situations this could be called in multiple instances
            base_arr.each{ |o|
                if not base_class_is_hash
                    if one_to_one
                        #attach name must be a string
                        o.questionable_attribute_set(as, nil, as_default: true)
                    else
                        o.questionable_attribute_set(as, [], as_default: true)
                    end
                elsif not one_to_one
                    o[as] ||= []
                end
            }

            #make sure the attach class has something going on. We do this after the default stage
            attach_arr = instaload_sql_output[attach_name]
            
            if attach_arr.nil? or not attach_arr.any?
                Rails.logger.warn("unable to find attach table " + attach_name)
                return 0
            end
            
            #   attach class information
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
            h = {}
            duplicates_base = Set[]
            for base_rec in base_arr
                bo = base_on.call(base_rec)
                if h[bo]
                    duplicates_base << bo
                else
                    h[bo] = base_rec
                end
            end
            
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
                if base_class_is_hash
                    if one_to_one
                        b[as] = a
                    else
                        b[as].push a
                    end
                else
                    #getting a lil tired of the meta stuff.
                    if one_to_one
                        b.questionable_attribute_set(as, a)
                    else
                        b.questionable_attribute_set(as, a, push: true)
                    end
                end
            }

            #for every attachable
            #	1. match base id to the attach id (both configurable)
            #	2. cancel out if there is no match
            #	3. otherwise add to the base object.
            x = 0

            attach_arr.each{|attach_rec|
                #we have it plural in case it attaches to multiple, for example a user can belong to many post-cards. Yes, this
                #was a bug. In order to solve it you have to do some sort of 'distinct' or 'group' sql.
                
                attachment_keys = attach_on.call(attach_rec) #you can use null to escape the vals
                
                if attachment_keys.nil?
                    Rails.logger.debug "attach_on proc output (which compares to the base_on proc) is outputting nil, this could be a problem depending on your use-case."
                elsif not attachment_keys.kind_of? Array
                    attachment_keys = [attachment_keys]
                end
                
                if attachment_keys and attachment_keys.any?
                    for ak in attachment_keys
                        base_rec = h[ak] #it is also escaped if no base element is found
                        if base_rec
                            dupl = duplicates_base.include? ak
                            if dupl
                                Rails.logger.warn "WARNING in #{attach_name} -> #{base_name}. Duplicate base_on key being utilized (this is usually in error). Only one base record will have an attachment. For the base table, consider using GROUP BY id and ARRAY_AGG for the base_on column."
                                Rails.logger.warn "base_on key: #{ak.to_s}"
                            end
                            
                            x += 1 unless dupl
                            add_to_base.call(base_rec, attach_rec)
                        end
                    end
                end
            }

            if Rails.logger.level <= 1
                #variable names are bad cause I switched them here
                tn = base_name
                an = attach_name
                x = instaload_sql_output[an]
                y = instaload_sql_output[tn]
                atc = x.count
                tc = y.count
                if as
                    Rails.logger.debug "#{n_attached}/#{atc} attached from #{an} as #{as} -> #{tn}(#{n_attached}/#{tc})"
                else
                    Rails.logger.debug "#{n_attached}/#{atc} attached from #{an} -> #{tn}(#{n_attached}/#{tc})"
                end
            end

            return x
        end
        alias swiss_attach dynamic_attach

        def zip_ar_result(x)
            x.to_a
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
		
		#undocumented and simple
        #def quick_safe_increment(id, col, val)
         #   where(id: id).update_all("#{col} = #{col} + #{val}")
        #end

        
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


	#undocumented and simple
 #   def safe_increment(col, val) #also used in follow, also used in comment#kill
#        self.class.where(id: self.id).update_all("#{col} = #{col} + #{val}")
  #  end

end
