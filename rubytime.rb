#!/usr/bin/env ruby

def bundler_installed?
  %x[gem list bundler].include?('bundler')
end

def install_bundler
  %x[gem install bundler]
end

def bundle_gems
  %x[gem bundle]
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

def read_with_default(prompt, default)
  puts("#{prompt}: [#{default}]")
  result = gets.strip
  result = default if result.strip.size == 0
  return result
end

def is_git_repo?
  return system('git log 2> /dev/null > /dev/null')
end

def get_commit_messages(date)
  day_after = date+1
  return %x[git log --all --no-merges --reverse --pretty=format:"%ad: %s%n%b" --since=#{date} --until=#{day_after} --author="`git config --get user.name`"]
end

def get_edited_message(msg)
  temp = Tempfile.new('message')
  file = File.new(temp.path, 'w+')
  file.puts msg
  file.close
  system("nano #{File.expand_path(file.path)}")
  return File.read(temp.path)
end

def get_message(date)
  msg = is_git_repo? ? get_commit_messages(date) : '<not a git repo>'
  return get_edited_message(msg)
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

def read_config
  YAML.load_file(config_file) rescue {}
end

def save_config(config)
  File.open(config_file, 'w+' ) do |out|
    YAML.dump(config, out)
  end
end

def get_from_config(config, prompt, group, value)
  result = config_value(config, group, value)
  unless result
    puts prompt
    result = gets.strip
  end
  set_config_value(config, group, value, result)
  return result
end

def get_rubytime_login(config)
  return get_from_config(config, 'Please input your rubytime login:', 'rubytime', 'login')
end

def get_rubytime_password(config)
  return get_from_config(config, 'Please input your rubytime password:', 'rubytime', 'password')
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
  config[group] && config[group][value]
end

def set_config_value(config, group, value, v)
  config[group] ||= {}
  config[group][value] = v
end

def get_field_by_name(form, name)
  field = form.fields.detect{|f| f.name == name}
  raise "field #{name} not found!" unless field
  return field
end

def get_project_to_select(agent, config)
  page = agent.get('http://rt.llp.pl/activities/new')
  form = page.forms.first
  raise "Form not found!" unless form
  select = form.fields.detect{|f| f.name == 'activity[project_id]'}
  raise "Select not found!" unless select

  print("Available projects:")
  select.options.each_with_index do |o, idx|
    printf("%2d) %s\n", idx+1, o.text)
  end
  selected = read_with_default('Select project', config_value(config, 'rubytime', 'project') || '1')
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
  return get_from_config(config, 'Please input your TickSpot password:', 'tickspot', 'password')
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
#    result = Hpricot.XML(response.body)
    result = response.body
  }
  return result
end

def update_tickspot(date, work_time, message, config)
  user = get_tickspot_login(config)
  pass = get_tickspot_password(config)
  domain = 'truvolabs.tickspot.com'

  txt = tickspot_request(user, pass, domain, 'projects', :open => true)
  doc = Nokogiri::XML.parse(txt)

  clients = {}
  doc.css('project').each do |project_elem|
    client_id = project_elem.css('client_id').first.content
    client_name = project_elem.css('client_name').first.content
    clients[client_id] = {:id => client_id, :name => client_name, :projects => []} unless clients[client_id]
    id = project_elem.css('id').first.content
    name = project_elem.css('name').first.content
    project = {:id => id, :name => name, :tasks => []}
    clients[client_id][:projects] << project
    project_elem.css('task').each do |task|
      task_id = task.css('id').first.content
      task_name = task.css('name').first.content
      project[:tasks] << {:id => task_id, :name => task_name}
    end
  end

  print('Clients')
  clients.each do |id, client|
    puts "#{client[:id]}: #{client[:name]}"
    puts "projects:"
    client[:projects].each do |project|
      puts "\t#{project[:id]}: #{project[:name]}"
      puts "\tTasks"
      project[:tasks].each do |task|
        puts "\t\t#{task[:id]}: #{task[:name]}"
      end
    end
  end

#  p doc.search('//project/').collect{|elem| {:id => (elem/'id').inner_html.strip, :name => (elem/'name').inner_html.strip} }
end

def main
  date = ARGV[0] ? Date.parse(ARGV[0]) : Date.today
  config = read_config()
#  msg = get_message(date)
#  print('Your message:', msg)
#  time = get_work_time(date)
#  print("Work time: #{time}")
#  update_rubytime(date, time, msg, config)
  update_tickspot(date, '01:00', 'test', config)
  save_config(config)
end

main()