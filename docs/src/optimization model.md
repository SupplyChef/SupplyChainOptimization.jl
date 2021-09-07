# Optimization Model

When the `optimize!` function is called it calls two other functions: `create_optimization_model` and `optimize_optimization_model!`.
`create_optimization_model` creates an optimization model and stores it in the supply chain `optimization_model` attribute. This process is
seamless and usually operates behind the scene. However there are cases where knowning about this process can be helpful. One such case is if 
a specific constraint needs to be added to the optimization model. 

The optimization model contains the following variables:
- sent
- opened
- closed