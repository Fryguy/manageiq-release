#!/usr/bin/env ruby

$LOAD_PATH << File.expand_path("../lib", __dir__)

require 'bundler/setup'
require 'manageiq/release'
require 'optimist'

DISPLAY_FORMATS = %w[commit pr-title pr-label]

opts = Optimist.options do
  opt :from,    "The commit log 'from' ref", :type => :string,  :required => true
  opt :to,      "The commit log 'to' ref" ,  :type => :string,  :required => true
  opt :display, "How to display the history. Valid values are: #{DISPLAY_FORMATS.join(", ")}", :default => "commit"
  opt :summary, "Display a summary of the repos.", :default => false

  opt :skip,   "The repos to skip", :default => ["manageiq-documentation"]

  ManageIQ::Release.common_options(self, :except => :dry_run)
end
Optimist.die :display, "must be one of: #{DISPLAY_FORMATS.join(", ")}" unless DISPLAY_FORMATS.include?(opts[:display])

range = "#{opts[:from]}..#{opts[:to]}"

puts "Git commit log between #{opts[:from]} and #{opts[:to]}\n\n"

repos_with_changes = []

def git_log(repo, range, include_graph:)
  options = {:oneline => true}
  options.merge!(:decorate => true, :graph => true) if include_graph
  repo.git.capturing.log(options, range)
rescue MiniGit::GitError
  puts "! Skipping. References for range #{range} do not exist."
  nil
end

ManageIQ::Release.repos_for(opts).each do |repo|
  next if repo.options.has_real_releases || repo.options.skip_tag
  next if opts[:skip].include?(repo.name)

  puts ManageIQ::Release.header(repo.name)
  repo.fetch(output: false)

  case opts[:display]
  when "pr-label", "pr-title"
    github ||= ManageIQ::Release.github
    pr_label_display = opts[:display] == "pr-label"

    results = {}
    if pr_label_display
      results["bug"] = []
      results["enhancement"] = []
    end
    results["other"] = []

    log = git_log(repo, range, include_graph: false)
    if log.present?
      log.lines.each do |line|
        next unless (match = line.match(/Merge pull request #(\d+)\b/))

        pr = github.pull_request(repo.github_repo.sub("IBMPrivateCloud", "ManageIQ").sub("bluecf", "manageiq"), match[1])
        label = pr.labels.detect { |l| results.key?(l.name) }&.name || "other"
        results[label] << pr
      end

      changes_found = false

      results.each do |label, prs|
        next if prs.blank?
        changes_found = true

        puts "\n## #{label.titleize}\n\n" if pr_label_display
        prs.each do |pr|
          puts "* #{pr.title} [[##{pr.number}]](#{pr.html_url})"
        end
      end

      repos_with_changes << repo if changes_found
    end
  when "commit"
    log = git_log(repo, range, include_graph: true)
    if log.present?
      puts log
      repos_with_changes << repo
    end
  end
  puts
end

if opts[:summary] && repos_with_changes.any?
  puts
  puts "Here are the changes per affected repository in GitHub:"
  repos_with_changes.each do |repo|
    from = opts[:from].split("/").last
    to   = opts[:to].split("/").last
    puts "* [#{repo.name}](https://github.com/#{repo.github_repo}/compare/#{from}...#{to})"
  end
  puts
end
