use lang_graphql::{
    ast::common::{self as ast, TypeName},
    mk_name,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    fmt::Display,
};

use open_dds::{commands, models, types};

use crate::metadata::resolved::{
    self,
    subgraph::{Qualified, QualifiedTypeReference},
};
use strum_macros::Display;

pub mod inbuilt_type;
pub mod input_type;
pub mod output_type;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct GlobalID {
    pub version: u16,
    pub typename: TypeName,
    /// Indexmap containing the name of the field and the
    /// value corresponding to the field that uniquely
    /// identify the object, these fields are declared in the
    /// `globalIdFields` with the object type.
    // We use BTreeMap here to keep the ordering of the
    // `FieldName`s consistent whenever it's serialized when the global ID
    // is constructed from more than one field, if
    // we don't do this, we may get a different Base 64 encoded
    // value every time, the `id` field is queried.
    pub id: BTreeMap<types::FieldName, Value>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct NodeFieldTypeNameMapping {
    pub type_name: Qualified<types::CustomTypeName>,
    pub model_source: Option<resolved::model::ModelSource>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum RootFieldKind {
    SelectOne,
    SelectMany,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum ModelFilterArgument {
    AndOp,
    OrOp,
    NotOp,
    Field { ndc_column: String },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub enum ModelOrderByDirection {
    Asc,
    Desc,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
/// Annotations of the GraphQL root field.
pub enum RootFieldAnnotation {
    Introspection,
    RelayNode {
        /// Contains the information required to execute the selection
        /// set of the node root field.
        /// The appropriate `NodeTypeNameMapping` is obtained by decoding
        /// the `id` argument and parsing it as a `GlobalID`. Then the,
        /// `typename` present in the `GlobalID` is used to look up
        /// in the `typename_mappings` which will contain the information
        /// about how the selection set should be executed.
        typename_mappings: HashMap<ast::TypeName, NodeFieldTypeNameMapping>,
    },
    Model {
        data_type: Qualified<types::CustomTypeName>,
        source: Option<resolved::model::ModelSource>,
        // select_permissions: HashMap<Role, resolved::SelectPermission>,
        kind: RootFieldKind,
        name: Qualified<models::ModelName>,
    },
    Command {
        name: Qualified<commands::CommandName>,
        underlying_object_typename: Option<Qualified<types::CustomTypeName>>,
        // A command may/may not have a source
        source: Option<resolved::command::CommandSource>,
    },
}

/// Annotations of the GraphQL output fields/types.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
pub enum OutputAnnotation {
    RootField(RootFieldAnnotation),
    Field {
        name: types::FieldName,
    },
    GlobalIDField {
        /// The `global_id_fields` are required to calculate the
        /// value of the `global_id`. Note that, the columns required
        /// to calculate the global id, may or may not be included in
        /// selection set of the query. In either case, we request all the
        /// fields required from the NDC agent prefixed with
        /// `GLOBAL_ID_NDC_PREFIX`, to avoid any conflicts between the
        /// fields requested in the user's selection set and the fields
        /// artificially added by us to calculate the Global ID value.
        global_id_fields: Vec<types::FieldName>,
    },
    RelationshipToModel(output_type::relationship::ModelRelationshipAnnotation),
    RelayNodeInterfaceID {
        typename_mappings: HashMap<ast::TypeName, Vec<types::FieldName>>,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
/// Annotations of the input types/fields related to Models.
pub enum ModelInputAnnotation {
    ModelArgumentsExpression,
    ModelArgument {
        argument_type: QualifiedTypeReference,
        ndc_table_argument: Option<String>,
    },
    ModelFilterExpression,
    ModelFilterArgument {
        field: ModelFilterArgument,
    },
    ModelFilterScalarExpression,
    ModelOrderByExpression,
    ModelOrderByArgument {
        ndc_column: String,
    },
    ModelOrderByDirection {
        direction: ModelOrderByDirection,
    },
    ModelLimitArgument,
    ModelOffsetArgument,
    ModelUniqueIdentifierArgument {
        field_name: types::FieldName,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
/// Annotations for GraphQL input arguments/types.
pub enum InputAnnotation {
    Model(ModelInputAnnotation),
    InputObjectField {
        field_name: types::FieldName,
        field_type: QualifiedTypeReference,
    },
    CommandArgument {
        argument_type: QualifiedTypeReference,
        ndc_func_proc_argument: Option<String>,
    },
}

/// Contains the different possible entities that can be used to generate
/// the `GDS` type which represents the internal state of the resolved metadata.
///
/// Each entity has two parts to it:
///
/// 1. What schema it is supposed to generate?
///      This is done while building the metadata. The entity is supposed to
///      contain all the data it needs to be able to execute it successfully.
///
/// 2. When a request is executed, how the entity is supposed to be executed using the data it has?
///
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
pub enum Annotation {
    Output(OutputAnnotation),
    Input(InputAnnotation),
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Display)]
pub enum NamespaceAnnotation {
    Filter(resolved::model::FilterPermission),
    /// The `NodeFieldTypeMappings` contains a Hashmap of typename to the filter permission.
    /// While executing the `node` field, the `id` field is supposed to be decoded and after
    /// decoding, a typename will be obtained. We need to use that typename to look up the
    /// Hashmap to get the appropriate `resolved::model::FilterPermission`.
    NodeFieldTypeMappings(
        HashMap<Qualified<types::CustomTypeName>, resolved::model::FilterPermission>,
    ),
}

#[derive(Serialize, Clone, Debug, Hash, PartialEq, Eq)]
pub enum TypeId {
    QueryRoot,
    MutationRoot,
    OutputType {
        gds_type_name: Qualified<types::CustomTypeName>,
        graphql_type_name: ast::TypeName,
    },
    ScalarType {
        gds_type_name: Qualified<types::CustomTypeName>,
        graphql_type_name: ast::TypeName,
    },
    InputObjectType {
        gds_type_name: Qualified<types::CustomTypeName>,
        graphql_type_name: ast::TypeName,
    },
    NodeRoot,
    ModelArgumentsInput {
        model_name: Qualified<models::ModelName>,
        type_name: ast::TypeName,
    },
    ModelBooleanExpression {
        model_name: Qualified<models::ModelName>,
        graphql_type_name: ast::TypeName,
    },
    ModelOrderByExpression {
        model_name: Qualified<models::ModelName>,
        graphql_type_name: ast::TypeName,
    },
    ScalarTypeComparisonExpression {
        scalar_type_name: String,
        graphql_type_name: ast::TypeName,
        operators: Vec<(ast::Name, QualifiedTypeReference)>,
    },
    OrderByEnumType,
}

impl Display for TypeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.to_type_name().fmt(f)
    }
}

impl TypeId {
    pub fn to_type_name(&self) -> ast::TypeName {
        match self {
            TypeId::QueryRoot => ast::TypeName(mk_name!("Query")),
            TypeId::MutationRoot => ast::TypeName(mk_name!("Mutation")),
            TypeId::OutputType {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::ScalarType {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::InputObjectType {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::NodeRoot => ast::TypeName(mk_name!("Node")),
            TypeId::ModelArgumentsInput { type_name, .. } => type_name.clone(),
            TypeId::ModelBooleanExpression {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::ScalarTypeComparisonExpression {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::ModelOrderByExpression {
                graphql_type_name, ..
            } => graphql_type_name.clone(),
            TypeId::OrderByEnumType => ast::TypeName(mk_name!("order_by")),
        }
    }
}
