class Explorer::CollectionsController < ExplorerController
  def index
   # redirect_to explorer_collections_path(current_database_name)
redirect_to explorer_collection_document_path(current_database_name, current_collection_name)
  end
  
  def show
  end

#POST
def create
    conn = MongoMapper.connection
    db = conn.db(current_database_name)
    db.create_collection(params[:coll])
 redirect_to explorer_collection_path(current_database_name, params[:coll])
end

#GET
  def new
    
  end
end
