@tool
extends Marker3D
class_name PileMarker

enum Kind { TABLEAU, FOUNDATION, STOCK, WASTE }
enum Suit { NONE, SPADES, HEARTS, DIAMONDS, CLUBS }

@export var kind: Kind = Kind.TABLEAU
@export var suit: Suit = Suit.NONE
