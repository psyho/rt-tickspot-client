#!/usr/bin/env ruby

def bundler_installed?
  %x[gem list bundler].include?('bundler')
end

def install_bundler
  %x[gem install bundler]
end

def bundle_gems
  %x[cd #{File.expand_path(File.dirname(__FILE__))}; gem bundle]
end

def print(text, data = nil)
  puts '=================='
  puts text
  puts '=================='
  puts data if data
  puts
end

print('Installing bundler', install_bundler()) unless bundler_installed?
print('Bundling gems', bundle_gems)

require File.expand_path(File.join(File.dirname(__FILE__), 'vendor', 'gems', 'environment'))
Bundler.require_env

require 'date'
require 'mechanize'
require 'tempfile'
require 'yaml'
require 'net/http'
require 'nokogiri'
require "highline/import"
require 'ezcrypto'

module Psyho
  class Config
    attr_accessor :password
    attr_accessor :data

    def initialize(password)
      @password = password
      @data = {}
    end

    def save(file_name)
      File.open(file_name, 'w+' ) do |out|
        YAML.dump(data, out)
      end
    end

    def load_from_file(file_name)
      @data = YAML.load_file(file_name) rescue {}
    end

    def [](group, value)
      stored = data[group] && data[group][value]
      return decrypt(stored)
    end

    def []=(group, value, to_set)
      data[group] ||= {}
      data[group][value] = to_set
    end

    def encrypt(value)
      return crypted_prefix+key.encrypt64(value).strip
    end

    protected

    def key
      @key ||= EzCrypto::Key.with_password(password, 'sup3rs@17ys@17')
    end

    def crypted_prefix
      '__crypted__'
    end

    def decrypt(value)
      if value.is_a?(String) && value.start_with?(crypted_prefix)
        encrypted = value.gsub(/^#{crypted_prefix}/, '').strip
        return key.decrypt64(encrypted)
      else
        return value
      end
    rescue OpenSSL::Cipher::CipherError => e
      raise "Wrong password!"
    end
  end
end

def read_with_default(prompt, default, explain = nil)
  explain = "(#{explain})" if explain
  puts("#{prompt}: [#{default}]#{explain}")
  result = STDIN.gets.strip
  result = default if result.strip.size == 0
  return result
end

def is_git_repo?
  return system('git log 2> /dev/null > /dev/null')
end

def format_date(date)
  "\"#{date.asctime}\""
end

def get_commit_messages(date)
  day_after = date+1
  return %x[git log --all --no-merges --reverse --pretty=format:"%ad: %s%n%b" --since=#{format_date(date)} --until=#{format_date(day_after)} --author="`git config --get user.name`"]
end

def get_edited_message(msg, editor)
  temp = Tempfile.new('message')
  file = File.new(temp.path, 'w+')
  file.puts msg
  file.close
  system("#{editor} #{File.expand_path(file.path)}")
  return File.read(temp.path)
end

def get_message(date, editor)
  msg = is_git_repo? ? get_commit_messages(date) : '<not a git repo>'
  return get_edited_message(msg, editor)
end

def get_work_time_today
  uptime = %x[cat /proc/uptime].split.first.to_i
  uptime_in_minutes = uptime / 60
  uptime_in_minutes -= 45
  uptime_in_minutes = uptime_in_minutes / 15 * 15
  hours = uptime_in_minutes / 60
  minutes = uptime_in_minutes % 60
  return hours, minutes
end

def get_default_work_time
  return 7, 15
end

def format_time(hours, minutes)
  sprintf('%02d:%02d', hours, minutes)
end

def get_work_time(date)
  hours, minutes = (date == Date.today ? get_work_time_today : get_default_work_time)
  time = format_time(hours, minutes)
  print("Calculated work time: #{time}")
  return read_with_default('Input work time', time)
end

def config_file
  File.expand_path("~/.rt")
end

def save_config(config)
  config.save(config_file)
end

def get_from_config(config, prompt, group, value, mask_input = false)
  result = config_value(config, group, value)
  unless result
    if mask_input
      result = ask(prompt) { |q| q.echo = "*" }
    else
      puts prompt
      result = STDIN.gets.strip
    end
  end
  set_config_value(config, group, value, result, mask_input)
  return result
end

def get_rubytime_login(config)
  return get_from_config(config, 'Please input your rubytime login:', 'rubytime', 'login')
end

def get_rubytime_password(config)
  return get_from_config(config, 'Please input your rubytime password: ', 'rubytime', 'password', true)
end

def login_to_rubytime(agent, pass, user)
  page = agent.get('http://rt.llp.pl/login')

  # Fill out the login form
  form = page.forms.detect{|f| f.action == '/login'}
  raise "Form /login not found!" unless form
  form.login = user
  form.password = pass
  agent.submit(form)
end

def config_value(config, group, value)
  config[group, value]
end

def set_config_value(config, group, value, v, encrypt = false)
  config[group, value] = (encrypt ? config.encrypt(v) : v)
  save_config(config)
  v
end

def get_field_by_name(form, name)
  field = form.fields.detect{|f| f.name == name}
  raise "field #{name} not found!" unless field
  return field
end

def get_project_to_select(agent, config)
  page = agent.get('http://rt.llp.pl/activities/new')
  page.parser.encoding = 'UTF-8' # doesn't always detect it for some reason

  form = page.forms.first
  raise "Form not found!" unless form
  select = form.fields.detect{|f| f.name == 'activity[project_id]'}
  raise "Select not found!" unless select
  
  print("Available projects:")
  select.options.each_with_index do |o, idx|
    printf("%2d) %s\n", idx+1, o.text)
  end
  selected = config_value(config, 'rubytime', 'project') || '1'
  selected = read_with_default('Select project', selected, select.options[selected.to_i-1].text)
  set_config_value(config, 'rubytime', 'project', selected)
  selected_option = select.options[selected.to_i - 1]
  puts
  print("Selected RubyTime Project: #{selected_option.text}")
  return form, select, selected_option
end

def submit_data_to_rubytime(agent, config, date, message, work_time)
  form, select, selected_option = get_project_to_select(agent, config)
  select.value = selected_option.value
  date_field = get_field_by_name(form, 'activity[date]')
  date_field.value = date
  hours_field = get_field_by_name(form, 'activity[hours]')
  hours_field.value = work_time
  comment_field = get_field_by_name(form, 'activity[comments]')
  comment_field.value = message
  agent.submit(form)
end

def update_rubytime(date, work_time, message, config)
  user = get_rubytime_login(config)
  pass = get_rubytime_password(config)

  agent = WWW::Mechanize.new
  login_to_rubytime(agent, pass, user)
  submit_data_to_rubytime(agent, config, date, message, work_time)
end

def get_tickspot_login(config)
  return get_from_config(config, 'Please input your TickSpot login:', 'tickspot', 'login')
end

def get_tickspot_password(config)
  return get_from_config(config, 'Please input your TickSpot password: ', 'tickspot', 'password', true)
end

def login_to_tickspot(agent, pass, user)
  page = agent.get('https://truvolabs.tickspot.com/login')

  form = page.forms.detect{|f| f.action == '/login'}
  raise "Form /login not found!" unless form
  form.user_login = user
  form.user_password = pass

  agent.submit(form)
end

def tickspot_request(user, pass, domain, path, params = {})
  request = Net::HTTP::Post.new("/api/" + path)
  request.form_data = {
      'email' => user,
      'password' => pass
  }.merge(params)

  result = nil
  Net::HTTP.new(domain).start {|http|
    response = http.request(request)
    result = response.body
    code = response.code.to_i
    raise "Request failed with code: #{code} and message #{response.body}" unless code < 300 && code >= 200
  }
  return result
end

def fix_html(str)
  return str.gsub('&amp;', '&')
end

def parse_client(project_elem)
  client_id = project_elem.css('client_id').first.content
  client_name = project_elem.css('client_name').first.content
  client = {:id => client_id, :name => fix_html(client_name), :projects => []}
  return client
end

def parse_project(project_elem)
  id = project_elem.css('id').first.content
  name = project_elem.css('name').first.content
  project = {:id => id, :name => fix_html(name), :tasks => []}
  return project
end

def parse_task(task)
  task_id = task.css('id').first.content
  task_name = task.css('name').first.content
  task = {:id => task_id, :name => fix_html(task_name)}
  return task
end

def parse_tickspot_clients(doc)
  clients = {}
  doc.css('project').each do |project_elem|
    client = parse_client(project_elem)
    clients[client[:id]] ||= client
    project = parse_project(project_elem)
    clients[client[:id]][:projects] << project
    project_elem.css('task').each do |task|
      project[:tasks] << parse_task(task)
    end
  end
  return clients
end

def get_tickspot_selected_id (config, collection, text)
  text_id = "#{text.downcase}_id"
  if collection.size == 1
    print("#{text}: #{collection.first[:name]}")
    selected_id = collection.first[:id]
  else
    selected_id = config_value(config, 'tickspot', text_id)
    selected_idx = '1'

    print("#{text}s")
    collection.each_with_index do |p, idx|
      puts "#{idx+1}) #{p[:name]}"
      if p[:id] == selected_id
        selected_idx = (idx+1).to_s
      end
    end
    selected_idx = read_with_default("Select #{text.downcase}", selected_idx, collection[selected_idx.to_i-1][:name])
    selected_id = collection[selected_idx.to_i-1][:id]
  end
  set_config_value(config, 'tickspot', text_id, selected_id)

  selected = collection.detect{|obj| obj[:id] == selected_id}

  return selected_id, selected
end

def update_tickspot(date, work_time, message, config)
  user = get_tickspot_login(config)
  pass = get_tickspot_password(config)
  domain = 'truvolabs.tickspot.com'

  txt = tickspot_request(user, pass, domain, 'projects', :open => true)
  doc = Nokogiri::XML.parse(txt)

  clients = parse_tickspot_clients(doc)
  client_id, client = get_tickspot_selected_id(config, clients.values, 'Client')
  project_id, project = get_tickspot_selected_id(config, client[:projects], 'Project')
  task_id, task = get_tickspot_selected_id(config, project[:tasks], 'Task')

  print('Selected values', "Client: #{client[:name]}\nProject: #{project[:name]}\nTask: #{task[:name]}")
  tickspot_request(user, pass, domain, 'create_entry', :task_id => task_id, :hours => work_time, :date => date, :notes => message)
end

def get_editor_command(config)
  unless config['editor', 'command']
    config['editor', 'command'] = read_with_default("Type your editor command", "nano")
    save_config(config)
  end
  editor = config['editor', 'command']
  return editor
end

def main
  date = ARGV[0] ? Date.parse(ARGV[0]) : Date.today
  password = ask('Please enter password to unlock config:') {|q| q.echo = '*'}
  config = Psyho::Config.new(password)
  config.load_from_file(config_file)
  editor = get_editor_command(config)
  msg = get_message(date, editor)
  print('Your message:', msg)
  time = get_work_time(date)
  print("Work time: #{time}")
  update_rubytime(date, time, msg, config)
  update_tickspot(date, time, msg, config)
  save_config(config)
end

main()