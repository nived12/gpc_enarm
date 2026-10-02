class AddEnarmModeToExams < ActiveRecord::Migration[8.1]
  def change
    add_column :exams, :enarm_mode, :boolean, default: false, null: false
  end
end
