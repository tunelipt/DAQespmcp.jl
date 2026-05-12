module DAQespmcp

using DAQCore
import DataStructures: CircularBuffer
import Dates: now

import LabDaqConfig: labdaqregister
import TOML

#include("wificlient.jl")
include("xmlrpc.jl")
#include("serial.jl")

end


