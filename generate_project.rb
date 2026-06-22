require 'xcodeproj'

project = Xcodeproj::Project.new('SomaAI.xcodeproj')
target = project.new_target: 'SomaAI', :product_type: 'application'

# Define folders and files
files = {
  "SomaAI/App" => ["Source/App/SomaAIApp.swift"],
  "SomaAI/Models" => ["Source/Models/Soma_AI_Models.swift"],
  "SomaAI/Views" => ["Source/Views/MainTabView.swift"]
}

files.each do |group_name, file_paths|
  group = project.main_group.new_group(group_name)
  file_paths.each do |path|
    file = project.new_file(path)
    group.add(file)
    target.add_file(file)
  end
end

project.save
