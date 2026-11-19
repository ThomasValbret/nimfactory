## NimFactory public façade.
## F0 contracts + Wave A domain modules. Full app composition remains F16.

import nimfactory/contracts
export contracts

import nimfactory/adapters/nimagent
export nimagent

import nimfactory/artifacts
export artifacts

import nimfactory/runtime/journal/journal
export journal

import nimfactory/graph/graph
export graph

import nimfactory/budget/budget
export budget

import nimfactory/runtime/executor
export executor

import nimfactory/application
export application

const
  NimFactoryVersion* = "0.1.0"
  NimAgentPinnedRevision* = "bf22665ece77d7149dbe61df959a6024bf6b26f3"
  NimAgentPinnedDescribe* = "v0.2.1-30-gbf22665"

proc factoryVersion*(): string = NimFactoryVersion
