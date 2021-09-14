# Optimization Model

The optimization model contains the following variables:

    - opened[plants_storages, times]: whether a plant or a storage location is opened during a given period.
    - opening[plants_storages, times]: whether a plant or a storage location is opening during a given period (it is now opened but was closed).
    - closing[plants_storages, times]: whether a plant or a storage location is closing during a given period (it is now closed but was opened).
    - bought[products, suppliers, times]: the amount of product bought from a supplier during a given period.
    - produced[products, plants, times]: the amount of product produced by a plant during a given period.
    - stored_at_start[products, storages, times]: the amount of product stored at a storage location at the beginning of a given period. 
    - stored_at_end[products, storages, times]: the amount of product stored at a storage location at the end of a given period.
    - used[lanes, times]: whether a lane is used during a given period.
    - sent[products, lanes, times]: the amount of product sent onto a lane during a given period.
    - received[products, lanes, times]: the amount of product received from a lane during a given period.
    - lost_sales[products, customers, times]: the amount of demand for a product by a customer lost during a given period.

See [Adding Special Constraints](@ref) for an example on how to use these variables to add constraints to the optimization model.