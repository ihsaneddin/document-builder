require 'grape-entity'

module Document
  module Grape
    module Presenters
      class Base < ::Grape::Entity

        root "data", "data"

      end
    end
  end
end