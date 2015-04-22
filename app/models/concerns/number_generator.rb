module NumberGenerator
  extend ActiveSupport::Concern

  NUMBER_LENGTH = 9
  NUMBER_LETTERS = false
  NUMBER_PREFIX = 'N'

  included do
    field :number, type: String
    validates :number, uniqueness: true
    validates_presence_of :number
    after_initialize :generate_number #, on: :create
  end

  def self.by_number(number)
    where(number: number)
  end

  def generate_number(options = {})
    options[:length] ||= NUMBER_LENGTH
    options[:letters] ||= NUMBER_LETTERS
    options[:prefix] ||= NUMBER_PREFIX

    possible = (0..9).to_a
    possible += ('A'..'Z').to_a if options[:letters]

    self.number ||= loop do
      # Make a random number.
      random = "#{options[:prefix]}#{(0...options[:length]).map { possible.shuffle.first }.join}"
      # Use the random  number if no other order exists with it.
      if self.number.present? && self.number == random
        # If over half of all possible options are taken add another digit.
        options[:length] += 1 if self.class.count > (10 ** options[:length] / 2)
      else
        break random
      end
    end
  end
end
