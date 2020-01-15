require 'pg_query'
require 'json'
require 'etcdv3'
require 'hashie'

class PgQueryOpt
  @etcd                  = nil
  @etcd_host             = nil
  @etcd_port             = nil
  @etcd_user             = nil
  @etcd_passwd           = nil
  @sql                   = nil
  @query_parser          = nil
  @user_id               = nil
  @username              = nil
  @db                    = nil
  @tag_sql               = nil
  @return_sql            = nil
  @query_tree            = nil
  @user_regex            = nil
  @default_scheme        = nil
  @default_scheme_tables = {}
  @data_in_etcd          = {}

  def set_prop(sql, username, db, etcd_host, etcd_port, etcd_user, etcd_passwd, user_regex, tag_regex, default_scheme, main_call)
    @sql         = sql
    @username    = username
    @db          = db
    @etcd_host   = etcd_host
    @etcd_port   = etcd_port
    @etcd_user   = etcd_user
    @etcd_passwd = etcd_passwd
    @user_regex  = user_regex
    @tag_regex   = tag_regex
    return nil unless main_call

    @default_scheme        = default_scheme
    @default_scheme_tables = {}
    @data_in_etcd          = {}
  end

  def get_role(sql)
    parser = if @sql
               @query_parser
             else
               PgQuery.parse(sql)
             end
    tree   = parser.tree
    tree.extend Hashie::Extensions::DeepFind
    keys  = tree.deep_find_all('FuncCall')
    keys2 = tree.deep_find_all('TransactionStmt')
    if keys.nil? && keys2.nil?
      'read'
    else
      'master'
    end
  end

  def get_subsql(key, return_sql)
    common = @query_tree.deep_find_all(key)
    unless common.nil?
      @query_tree.deep_find_all(key).each do |i|

        subselect_sql = @query_parser.deparse([i])
        set_prop(subselect_sql, @username, @db, @etcd_host, @etcd_port, @etcd_user, @etcd_passwd, @user_regex, @tag_regex, @default_scheme, false)

        subselect_sql_changed = get_sql
        return_sql            = return_sql.gsub subselect_sql, subselect_sql_changed
      end
    end
    return_sql
  end

  def get_sql
    @pass_tag = /#{@tag_regex}/.match(@sql)
    return @sql if @pass_tag

    #puts @sql

    @query_parser = PgQuery.parse(@sql)
    @sql          = @sql.strip
    @tag_sql      = /(?<=^\/\*)([^\*]*)(?=\*\/)/.match(@sql)
    @tag_sql      = @tag_sql ? '/* ' + @tag_sql[1].strip + ' */' : ''
    if @user_id.nil?
      @user_id = /#{@user_regex}/.match(@sql)

      @user_id = @user_id[1].strip if @user_id
    end
    # if @pass_tag
    #   @pass_tag = @pass_tag[1].strip
    #   conn_etcd
    #   regex_tag = @etcd.get(@pass_tag)
    #
    #   if regex_tag.count > 0
    #     regex_tag = regex_tag.kvs.first.value
    #
    #   end
    # end
    i = 0
    # puts @query_parser.tree
    for query in @query_parser.tree
      @query_tree = query
      @query_tree.extend Hashie::Extensions::DeepFind

      resolve_stars
      check_rules(nil)
      add_filter

      @query_parser.tree[i] = @query_tree
      i                     += 1
    end

    return_sql = @query_parser.deparse

    return_sql = get_subsql('subselect', return_sql)

    return_sql = get_subsql('ctequery', return_sql)

    return_sql = get_subsql('subquery', return_sql)

    #puts '-------------------------'
    #puts @query_parser.tree
    #puts '-------------------------'
    #puts @tag_sql + return_sql
    #puts '-------------------------'
    return @tag_sql + return_sql
  rescue => e
    puts e
    puts e.backtrace.to_s
    return @sql
  end

  def etcd_data(filter_id)
    if @data_in_etcd[filter_id].nil?
      data                     = @etcd.get(filter_id)
      @data_in_etcd[filter_id] = data

    end
    @data_in_etcd[filter_id]
  end

  def check_default_scheme(schema, table, p)
    column = if schema.nil?
               if table.include? '.'
                 table
               else
                 if @default_scheme_tables[table].nil?
                   for scheme_name in @default_scheme.split(',') do
                     table_name    = scheme_name.strip + '.' + table
                     table_in_etcd = etcd_data('/' + @db + '/' + table_name.tr('.', '/'))
                     break if table_in_etcd.count > 0
                   end
                   @default_scheme_tables[table] = table_name
                   table_name
                 else
                   @default_scheme_tables[table]
                 end

               end
             else
               schema + '.' + table
             end
    column.tr('.', p)
  end


  def add_filter
    @query_parser.tables.each do |col|
      etcd_schema_table = check_default_scheme(nil, col, '.')
      etcd_key          = '/sqlfilter/' + @db + '/' + etcd_schema_table.tr('.', '/')
      filter            = etcd_data(etcd_key)
      next unless filter.count > 0

      filter_arr = JSON.parse(filter.kvs.first.value)
      next unless filter_arr['enabled'] == 'true'


      search_area = @query_tree['RawStmt']['stmt']['SelectStmt']['fromClause']
      search_area.extend Hashie::Extensions::DeepFind

      pass = true
      for x in search_area.deep_find_all('RangeVar')
        table_name = check_default_scheme(x['schemaname'], x['relname'], '.')

        next unless table_name == etcd_schema_table

        pass  = false
        sql_w = if x['alias'].nil?
                  (filter_arr['filter'])
                else
                  (filter_arr['filter']).tr('"', '').gsub(etcd_schema_table, x['alias']['Alias']['aliasname'])
                end
      end

      next if pass

      xx = PgQuery.parse('SELECT WHERE ' + sql_w)

      xx_tree = xx.tree

      filter_w = []

      filter_w.push(xx_tree[0]['RawStmt']['stmt']['SelectStmt']['whereClause'])
      filter_w.push(@query_tree['RawStmt']['stmt']['SelectStmt']['whereClause']) unless @query_tree['RawStmt']['stmt']['SelectStmt']['whereClause'].nil?
      @query_tree['RawStmt']['stmt']['SelectStmt']['whereClause'] = { 'BoolExpr' => { 'boolop' => 0, 'args' => filter_w } }

    end
  end

  def check_rules(column_ref)
    if column_ref.nil?
      list = get_column_list
      i    = -1
      list.each do |col|
        i += 1
        k = 0
        unless col['ResTarget']['val']['FuncCall'].nil?
          col['ResTarget']['val']['FuncCall']['args'].each do |col_ref|
            if col_ref['FuncCall'].nil?
              rule                                                                                                     = make_rules(col_ref, nil)
              @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'][i]['ResTarget']['val']['FuncCall']['args'][k] = rule['ResTarget']['val'] unless rule.nil?

            else
              check_rules(col_ref['FuncCall']['args'])
            end

            k += 1
          end
        end

        unless col['ResTarget']['val']['A_Expr'].nil?
          unless col['ResTarget']['val']['A_Expr']['lexpr'].nil?
            if col['ResTarget']['val']['A_Expr']['lexpr']['FuncCall'].nil?
              rule = make_rules(col['ResTarget']['val']['A_Expr']['lexpr'], nil)
              unless rule.nil?
                # if col_ref['FuncCall'].nil?
                # puts rule
                @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'][i]['ResTarget']['val']['A_Expr']['lexpr']['ColumnRef']['fields'][0] = rule['ResTarget']['val']
              end
            else
              check_rules(col['ResTarget']['val']['A_Expr']['lexpr']['FuncCall']['args'])
            end
          end

          unless col['ResTarget']['val']['A_Expr']['rexpr'].nil?
            if col['ResTarget']['val']['A_Expr']['rexpr']['FuncCall'].nil?
              rule = make_rules(col['ResTarget']['val']['A_Expr']['rexpr'], nil)
              unless rule.nil?
                # if col_ref['FuncCall'].nil?
                # puts rule
                @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'][i]['ResTarget']['val']['A_Expr']['rexpr']['ColumnRef']['fields'][0] = rule['ResTarget']['val']
              end
            else
              check_rules(col['ResTarget']['val']['A_Expr']['rexpr']['FuncCall']['args'])
            end
          end
        end

        next if col['ResTarget']['val']['ColumnRef'].nil?

        rule = make_rules(col['ResTarget']['val'], col['ResTarget']['name'])
        unless rule.nil?
          if rule['del'].nil?
            @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'][i] = rule
          else
            @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'].delete_at(i)
          end
        end
      end
    else
      j = 0
      column_ref.each do |col_ref|
        check_rules(col_ref['FuncCall']['args']) unless col_ref['FuncCall'].nil?
        rules = make_rules(col_ref, nil)
        next if rules.nil?

        if rules['del'].nil?
          column_ref[j] = rules['ResTarget']['val']
        else
          column_ref.delete_at(j)
        end
        j += 1
      end
      column_ref

    end
  end

  def make_rules(column_ref, column_name)
    rule_list         = {}
    user_rule_list    = {}
    return_column_ref = {}
    return nil if column_ref['ColumnRef'].nil?

    col_detail = column_ref['ColumnRef']['fields']

    return nil unless col_detail[0]['A_Star'].nil?

    col_prefix    = ''
    col_name_last = nil
    if col_detail.count == 3
      col_prefix    = '/' + @db + '/' + col_detail[0] + '/' + col_detail[1]
      col_name_last = col_detail[2]
    elsif col_detail.count == 2
      if col_detail[0].is_a?(String)
        table         = @query_parser.aliases[col_detail[0]]
        table         = col_detail[0] if table.nil?
        col_prefix    = change_col_names_for_etcd(table)
        col_name_last = col_detail[1]
      else
        nil unless col_detail[1]['A_Star'].nil?

        table         = @query_parser.aliases[col_detail[0]['String']['str']]
        col_prefix    = change_col_names_for_etcd(table)
        col_name_last = col_detail[1]['String']['str']
      end
    elsif col_detail.count == 1
      @query_parser.tables.each do |table|
        xx            = etcd_data(change_col_names_for_etcd(table))
        col_detail[0] = col_detail[0]['String']['str'] unless col_detail[0].is_a?(String)
        if JSON.parse(xx.kvs.first.value).select { |h| h['column_name'] == col_detail[0] }.count > 0
          col_prefix    = change_col_names_for_etcd(table)
          col_name_last = col_detail[0]
        end
      end

    end
    return nil if col_name_last.nil? or col_prefix.nil?

    col_name = '/rules' + col_prefix
    if rule_list[col_name].nil?
      rule                = @etcd.get(col_name, range_end: col_name + '0')
      rule_list[col_name] = {}
      if rule.count > 0
        rule.kvs.each do |xx|
          key = {}
          if (rule_list[col_name][xx.key.split('/groups')[0]]).nil?
            key['kvs'] = [xx]
          else
            key['kvs'] = rule_list[col_name][xx.key.split('/groups')[0]]['kvs']
            key['kvs'].push(xx)
          end
          key['count'] = key['kvs'].count

          rule_list[col_name][xx.key.split('/groups')[0]] = key
        end
      end
    end
    rule = rule_list[col_name][col_name + '/' + col_name_last]

    return nil unless !rule.nil? and rule['count'] > 0

    rule['kvs'].each do |rules|
      group_name = JSON.parse(rules.value)['group_name']
      user       = nil
      unless @user_id.nil?
        if (user_rule_list['/users/' + @user_id + group_name]).nil?
          user                                              = etcd_data('/users/' + @user_id + group_name)
          user_rule_list['/users/' + @user_id + group_name] = user
        else
          user = user_rule_list['/users/' + @user_id + group_name]
        end
        if user.count > 0
          user = nil if JSON.parse(user.kvs.first.value)['enabled'] == 'false'
        end
      end
      if @user_id.nil? or user.nil? or user.count == 0
        if (user_rule_list['/dbuser/' + @username + group_name]).nil?
          user                                                = etcd_data('/dbuser/' + @username + group_name)
          user_rule_list['/dbuser/' + @username + group_name] = user
        else
          user = user_rule_list['/dbuser/' + @username + group_name]
        end
      end
      next unless user.count > 0
      next unless JSON.parse(user.kvs.first.value)['enabled'] == 'true'
      ""
      group_rule = etcd_data(group_name)
      next unless group_rule.count > 0

      rules_group = JSON.parse(group_rule.kvs.first.value)

      next if rules_group['enabled'] == 'false'

      if rules_group['rule'] == 'send_null'
        if column_name.nil?
          col_name = column_ref['ColumnRef']['fields'][-1]
          col_name = col_name['String']['str'] unless col_name.is_a?(String)
        else
          col_name = column_name
        end
        return_column_ref = { 'ResTarget' => { 'name' => col_name, 'val' => { 'A_Const' => { 'val' => { 'Null' => {} } } } } }
      elsif rules_group['rule'] == 'delete_col'
        return_column_ref = { 'del' => 1 }
      else
        # if rules_group['rule'] == "partial"
        if column_name.nil?
          col_name = column_ref['ColumnRef']['fields'][-1]
          col_name = col_name['String']['str'] unless col_name.is_a?(String)
        else
          col_name = column_name
        end
        xx = JSON.parse(rules_group['prop'].gsub('%col%', column_ref.to_json))

        func = { 'funcname' => [{ 'String' => { 'str' => 'mask' } }, { 'String' => { 'str' => rules_group['rule'] } }], 'args' => xx }
        # TODO: Schema is not dynamic
        return_column_ref = { 'ResTarget' => { 'name' => col_name, 'val' => { 'FuncCall' => func } } }
      end
    end
    return_column_ref
  end

  def conn_etcd
    if @etcd.nil?
      @etcd = if @etcd_user.empty?
                Etcdv3.new(endpoints: 'http://' + @etcd_host + ':' + @etcd_port, command_timeout: 5)
              else
                Etcdv3.new(endpoints: 'http://' + @etcd_host + ':' + @etcd_port, command_timeout: 5, user: @etcd_user, password: @etcd_passwd)
              end
    end
  end

  def get_col_list_in_etcd(table, table_alias, col_alias)
    columns  = []
    col_list = etcd_data(table)
    if col_list.count > 0
      JSON.parse(col_list.kvs.first.value).each do |val|
        columns.push([col_alias, table_alias, val['column_name']])
      end
    end
    columns
  end

  def star_column(all_fields)
    unless (@query_tree['RawStmt']['stmt']['SelectStmt']).nil?
      @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'] = []
      if all_fields.count > 0
        all_fields.each do |val|
          if val.is_a?(Array)
            extra = val[0]
            val.delete_at(0)
            if val[0].include? '.'
              val_end    = val[0].split('.')
              val_end[2] = val[1]
              val        = val_end
            end
            @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'].push({ 'ResTarget' => { 'name' => extra, 'val' => { 'ColumnRef' => { 'fields' => val } } } })
          elsif !val['A_Star'].nil?
            @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'].push({ 'ResTarget' => { 'val' => { 'ColumnRef' => { 'fields' => [val] } } } })
          else
            @query_tree['RawStmt']['stmt']['SelectStmt']['targetList'].push(val)
          end

        end
      end
    end
  end

  def get_column_list
    list = if @query_tree['RawStmt']['stmt']['SelectStmt'].nil?
             []
           else
             @query_tree['RawStmt']['stmt']['SelectStmt']['targetList']
           end
    list
  end

  def change_col_names_for_etcd(table)
    if !table.nil?
      '/' + @db + '/' + check_default_scheme(nil, table, '/')
    else
      table
    end
  end

  def resolve_stars
    conn_etcd
    all_fields = []

    xx = @query_parser.tree
    xx.extend Hashie::Extensions::DeepFind

    table_list = []
    unless @query_tree['RawStmt']['stmt']['SelectStmt'].nil?
      unless @query_tree['RawStmt']['stmt']['SelectStmt']['fromClause'].nil?
        for k in @query_tree['RawStmt']['stmt']['SelectStmt']['fromClause']
          if !k['JoinExpr'].nil?
            k.extend Hashie::Extensions::DeepFind
            unless k.deep_find('subquery')
              k.deep_find_all('RangeVar').each do |find_tables|
                if find_tables['schemaname'].nil?
                  table_list.push(find_tables['relname'])
                else
                  table_list.push(find_tables['schemaname'] + '.' + find_tables['relname'])
                end
              end
            end
          elsif !k['RangeVar'].nil?
            if k['RangeVar']['schemaname'].nil?
              table_list.push(k['RangeVar']['relname'])
            else
              table_list.push(k['RangeVar']['schemaname'] + '.' + k['RangeVar']['relname'])
            end
          end
        end

      end


      get_column_list.each do |name|
        i     = 0
        field = []
        if !name['ResTarget']['val']['ColumnRef'].nil?
          col_alias = nil
          col_alias = name['ResTarget']['name'] if name['ResTarget']['name']
          field.push(col_alias)

          field_list = name['ResTarget']['val']['ColumnRef']['fields']
          field_list.each do |list|
            if list['A_Star']
              if i == 1
                table_alias = field_list[0]['String']['str']
                table       = @query_parser.aliases[table_alias]
                if table.nil?
                  cvcv = []
                  cvcv.push(nil)
                  all_fields.concat([cvcv.concat(field_list)])
                else
                  all_fields.concat(get_col_list_in_etcd(change_col_names_for_etcd(table), table_alias, col_alias))
                end
              else
                col_names   = []
                last_add    = false
                search_area = @query_tree['RawStmt']['stmt']['SelectStmt']['fromClause']
                search_area.extend Hashie::Extensions::DeepFind

                search_area.deep_find_all('RangeVar').each do |val|
                  table = check_default_scheme(val['schemaname'], val['relname'], '.')

                  table_alias = if val['alias'].nil?
                                  table
                                else
                                  val['alias']['Alias']['aliasname']
                                end
                  col_names   = get_col_list_in_etcd(change_col_names_for_etcd(table), table_alias, col_alias)

                  if col_names.nil? || col_names.count.zero?
                    last_add = true
                    all_fields.push(list)
                  else
                    last_add = false
                    all_fields.concat(col_names)
                  end
                end
                all_fields.push(list) if (col_names.nil? || col_names.count.zero?) && last_add == false
              end
              field = []
            else
              field.push(list)
            end
            i += 1
          end
          all_fields.push(field) if field.count > 0
        else
          all_fields.push(name)
        end
      end
    end
    star_column(all_fields)
    all_fields
  end

  def tree
    @query_parser.tree
  end
end

