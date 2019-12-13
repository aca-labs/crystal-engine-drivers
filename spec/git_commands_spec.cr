require "./spec_helper"
require "yaml"

module ACAEngine::Drivers
  describe GitCommands do
    it "should list files in the repository" do
      files = ACAEngine::Drivers::GitCommands.ls
      (files.size > 0).should be_true
      files.includes?("shard.yml").should be_true
    end

    it "should list the revisions to a file in a repository" do
      changes = ACAEngine::Drivers::GitCommands.commits("shard.yml", count: 200)
      (changes.size > 0).should be_true
      changes.map { |commit| commit[:subject] }.includes?("restructure application").should be_true
    end

    it "should list the revisions of a repository" do
      changes = ACAEngine::Drivers::GitCommands.repository_commits(count: 200)
      (changes.size > 0).should be_true
      changes.map { |commit| commit[:subject] }.includes?("restructure application").should be_true
    end

    it "should checkout a particular revision of a file and then restore it" do
      # Check the current file
      yaml = File.open("shard.yml") { |file| YAML.parse(file) }
      name = yaml["name"].to_s
      (name == "engine-drivers").should be_true

      # Process a particular commit
      ACAEngine::Drivers::GitCommands.checkout("shard.yml", "18f149d") do
        yaml = File.open("shard.yml") { |file| YAML.parse(file) }
        (yaml["name"].to_s == "app").should be_true
      end

      # File should have reverted
      yaml = File.open("shard.yml") { |file| YAML.parse(file) }
      (yaml["name"].to_s).should eq(name)
    end

    it "should checkout a file and then restore it on error" do
      # Check the current file
      yaml = File.open("shard.yml") { |file| YAML.parse(file) }
      name = yaml["name"].to_s
      (name == "engine-drivers").should be_true

      # Process a particular commit
      expect_raises(Exception, "something went wrong") do
        ACAEngine::Drivers::GitCommands.checkout("shard.yml", "18f149d") do
          yaml = File.open("shard.yml") { |file| YAML.parse(file) }
          (yaml["name"].to_s == "app").should be_true

          raise "something went wrong"
        end
      end

      # File should have reverted
      yaml = File.open("shard.yml") { |file| YAML.parse(file) }
      (yaml["name"].to_s).should eq(name)
    end
  end
end