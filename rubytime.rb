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

def print(text, data)
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

def main
  date = ARGV[0] ? Date.parse(ARGV[0]) : Date.today
  msg = get_message(date)
  print('Your message:', msg)
end

main()